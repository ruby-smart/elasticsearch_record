# frozen_string_literal: true

# Specs for +#translate_exception+ - the single place where +::Elastic::Transport+
# errors are mapped onto the +ActiveRecord+ exception hierarchy.
#
# The mapping is a +case+ over the transport error classes, so the ORDER of the
# branches carries meaning: +BadRequest+, +Conflict+, +RequestTimeout+, ... are all
# descendants of +::Elastic::Transport::Transport::ServerError+, which is the catch-all
# branch and therefore MUST stay last. The examples below assert the *exact* resulting
# class (never +be_a+) - +QueryCanceled+, +StatementTimeout+, +RecordNotUnique+ and
# +DatabaseAlreadyExists+ all inherit from +StatementInvalid+, so a +be_a+ expectation
# would silently pass if a branch got reordered into the catch-all.
#
# These specs do NOT need a live cluster - the adapter is instantiated without
# connecting and the exceptions are handed in directly.
RSpec.describe ActiveRecord::ConnectionAdapters::ElasticsearchAdapter do
  subject(:adapter) do
    described_class.new(ElasticsearchSpec::CONFIG.symbolize_keys)
  end

  # +#translate_exception+ is private (as in +AbstractAdapter+) and is reached through
  # +#translate_exception_class+ from +#log+.
  def translate(exception, message: "translated: #{exception.message}", sql: :some_query, binds: [])
    adapter.send(:translate_exception, exception, message: message, sql: sql, binds: binds)
  end

  # shorthand for the (deeply nested) transport error namespace
  transport_errors = ::Elastic::Transport::Transport::Errors

  describe '#translate_exception' do
    context 'with ::Elastic::Transport::Transport::Errors::ClientClosedRequest' do
      let(:exception) { transport_errors::ClientClosedRequest.new('client closed request') }

      it 'returns a ActiveRecord::QueryCanceled' do
        expect(translate(exception).class).to eq(::ActiveRecord::QueryCanceled)
      end
    end

    context 'with ::Elastic::Transport::Transport::Errors::RequestTimeout' do
      let(:exception) { transport_errors::RequestTimeout.new('request timeout') }

      it 'returns a ActiveRecord::StatementTimeout' do
        expect(translate(exception).class).to eq(::ActiveRecord::StatementTimeout)
      end

      # +#retryable_query_error?+ only retries +StatementTimeout+ / +Deadlocked+ /
      # +LockWaitTimeout+ - so this mapping is what makes a timed out request retryable.
      it 'returns a retryable error' do
        expect(adapter.send(:retryable_query_error?, translate(exception))).to be(true)
      end
    end

    context 'with ::Elastic::Transport::Transport::Errors::Conflict' do
      let(:exception) { transport_errors::Conflict.new('version conflict, document already exists') }

      it 'returns a ActiveRecord::RecordNotUnique' do
        expect(translate(exception).class).to eq(::ActiveRecord::RecordNotUnique)
      end
    end

    context 'with ::Elastic::Transport::Transport::Errors::BadRequest' do
      # Elasticsearch answers a 'create index' on an existing index with a 400 carrying a
      # +resource_already_exists_exception+ - the only way to tell it from any other bad request.
      context 'with a resource_already_exists_exception message' do
        let(:exception) do
          transport_errors::BadRequest.new(
            '[400] {"error":{"root_cause":[{"type":"resource_already_exists_exception",' \
            '"reason":"index [elasticsearch_record_test/xyz] already exists"}]},"status":400}'
          )
        end

        it 'returns a ActiveRecord::DatabaseAlreadyExists' do
          expect(translate(exception).class).to eq(::ActiveRecord::DatabaseAlreadyExists)
        end
      end

      context 'with any other message' do
        let(:exception) { transport_errors::BadRequest.new('[400] {"error":"parsing_exception"}') }

        it 'returns a ActiveRecord::StatementInvalid' do
          expect(translate(exception).class).to eq(::ActiveRecord::StatementInvalid)
        end
      end
    end

    context 'with ::Elastic::Transport::Transport::Errors::Unauthorized' do
      let(:exception) { transport_errors::Unauthorized.new('[401] unauthorized') }

      it 'returns a ActiveRecord::DatabaseConnectionError' do
        expect(translate(exception).class).to eq(::ActiveRecord::DatabaseConnectionError)
      end

      # the username is read from +@config[:username]+ - mirroring +.new_client+, which raises
      # the same error (but from +config[:user]+) when the client cannot authenticate.
      context 'with a :username configured' do
        subject(:adapter) do
          described_class.new(ElasticsearchSpec::CONFIG.symbolize_keys.except(:user).merge(username: 'elastic'))
        end

        it 'reports the configured username' do
          expect(translate(exception).message).to include('username: elastic')
        end
      end

      # PLEASE NOTE: the adapter accepts +:user+ as well (+#initialize+ moves it to +:user+ for the
      # client) - but +#translate_exception+ only looks at +:username+, so a +:user+-only
      # configuration produces a blank username here. Pinned to document the current behaviour.
      context 'with only a :user configured' do
        it 'reports a blank username' do
          expect(translate(exception).message).to include('username: .')
        end
      end

      # the +DatabaseConnectionError+ is built from the config only - +message+, +sql+ & +binds+
      # of the original request are not forwarded.
      it 'does not forward the provided message' do
        expect(translate(exception).message).not_to include('translated:')
      end
    end

    # the catch-all branch: every other transport 'ServerError' (404, 500, 503, ...)
    # becomes a plain +StatementInvalid+.
    context 'with any other ::Elastic::Transport::Transport::ServerError' do
      [:NotFound, :Forbidden, :InternalServerError, :ServiceUnavailable, :TooManyRequests].each do |name|
        context "with ::Elastic::Transport::Transport::Errors::#{name}" do
          let(:exception) { transport_errors.const_get(name).new("[xxx] #{name}") }

          it 'returns a ActiveRecord::StatementInvalid' do
            expect(translate(exception).class).to eq(::ActiveRecord::StatementInvalid)
          end
        end
      end
    end

    # +ServerError+ is the last matched branch - a bare +Transport::Error+ (its superclass,
    # e.g. raised by the transport itself on 'no healthy connection') is NOT a ServerError
    # and must fall through untouched.
    context 'with a ::Elastic::Transport::Transport::Error' do
      let(:exception) { ::Elastic::Transport::Transport::Error.new('Cannot get new connection from pool.') }

      it 'forwards the original exception' do
        expect(translate(exception)).to be(exception)
      end
    end

    context 'with a non-Elasticsearch exception' do
      let(:exception) { ArgumentError.new('wrong number of arguments') }

      it 'forwards the original exception' do
        expect(translate(exception)).to be(exception)
      end
    end

    # everything but the +Unauthorized+ branch forwards the request context into the
    # created error - this is what makes the failing query readable in the logs.
    describe 'forwarded query context' do
      let(:exception) { transport_errors::Conflict.new('version conflict') }
      let(:binds) { [1, 2] }

      subject(:translated) { translate(exception, message: 'a message', sql: :some_query, binds: binds) }

      it 'keeps the provided message' do
        expect(translated.message).to eq('a message')
      end

      it 'keeps the provided sql' do
        expect(translated.sql).to eq(:some_query)
      end

      it 'keeps the provided binds' do
        expect(translated.binds).to eq(binds)
      end

      it 'assigns the connection pool' do
        expect(translated.connection_pool).to eq(adapter.pool)
      end
    end
  end

  # +#log+ wraps every +#api+ call and is the only caller of +#translate_exception+
  # (through +AbstractAdapter#translate_exception_class+).
  describe '#log' do
    def log_raising(exception)
      adapter.send(:log, 'indices.create', { index: 'elasticsearch_record_test' }) { raise exception }
    end

    it 'translates a raised transport error' do
      expect { log_raising(transport_errors::Conflict.new('version conflict')) }
        .to raise_error(::ActiveRecord::RecordNotUnique)
    end

    # +#translate_exception_class+ builds the message as '<class>: <message>' and passes the
    # gate +arguments+ as 'sql' - so the failing request stays visible on the error.
    it 'forwards the original message and the request arguments' do
      expect { log_raising(transport_errors::Conflict.new('version conflict')) }
        .to raise_error(::ActiveRecord::RecordNotUnique) { |error|
          expect(error.message).to eq('Elastic::Transport::Transport::Errors::Conflict: version conflict')
          expect(error.sql).to eq({ index: 'elasticsearch_record_test' })
          expect(error.binds).to eq([])
        }
    end

    # +#translate_exception_class+ returns ActiveRecord errors untouched - this is how the
    # +StatementTimeout+ raised by +#api+ for a 'timed_out' response survives.
    it 'does not re-translate an ActiveRecord error' do
      expect { log_raising(::ActiveRecord::StatementTimeout.new('Elasticsearch api request failed due a timeout')) }
        .to raise_error(::ActiveRecord::StatementTimeout, 'Elasticsearch api request failed due a timeout')
    end

    it 'does not translate a non-Elasticsearch exception' do
      expect { log_raising(ArgumentError.new('nope')) }.to raise_error(ArgumentError, 'nope')
    end
  end
end
