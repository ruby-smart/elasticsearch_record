# frozen_string_literal: true

# Covers +Arel::Collectors::ElasticsearchQuery#claim+ & +#assign+.
#
# +claim+ is the ONLY way the visitor talks to the collector - every +visit_*+ method ends in a
# claim, and the collector IS the +ElasticsearchRecord::Query+ that is later dispatched to the API.
# +assign+ is its private counterpart for the query BODY, reachable through the +:assign+ action.
#
# PLEASE NOTE: these specs never touch a cluster - the collector is plain Ruby.
#
# see @ Arel::Collectors::ElasticsearchQuery
# see @ Arel::Visitors::ElasticsearchBase#claim
RSpec.describe Arel::Collectors::ElasticsearchQuery do
  subject(:collector) { described_class.new }

  describe '#claim' do
    it 'starts with an empty body' do
      expect(collector.body).to eq({})
    end

    # every one of these actions simply REPLACES the related attribute
    {
      index:     ['my-index', :index],
      type:      [ElasticsearchRecord::Query::TYPE_SEARCH, :type],
      status:    [ElasticsearchRecord::Query::STATUS_FAILED, :status],
      refresh:   [true, :refresh],
      timeout:   ['1m', :timeout],
      columns:   [%w[name count], :columns],
      arguments: [{ terminate_after: 5 }, :arguments]
    }.each do |action, (value, reader)|
      describe "action :#{action}" do
        it "sets the ##{reader}" do
          collector.claim(action, value)

          expect(collector.public_send(reader)).to eq(value)
        end

        it 'replaces a previously claimed value' do
          collector.claim(action, value)
          collector.claim(action, nil)

          expect(collector.public_send(reader)).to be_nil
        end
      end
    end

    describe 'action :body' do
      it 'sets the body' do
        collector.claim(:body, { query: { match_all: {} } })

        expect(collector.body).to eq({ query: { match_all: {} } })
      end

      it 'replaces the whole body - including previous assigns' do
        collector.claim(:assign, :size, 5)
        collector.claim(:body, { query: { match_all: {} } })

        expect(collector.body).to eq({ query: { match_all: {} } })
      end

      # a msearch body is an Array - the body is not restricted to Hashes
      it 'accepts a non-Hash body' do
        collector.claim(:body, [{ search: { query: {} } }])

        expect(collector.body).to eq([{ search: { query: {} } }])
      end
    end

    describe 'action :argument' do
      it 'sets a single argument through a provided key & value' do
        collector.claim(:argument, :terminate_after, 5)

        expect(collector.arguments).to eq({ terminate_after: 5 })
      end

      it 'merges a provided Hash into the existing arguments' do
        collector.claim(:argument, :terminate_after, 5)
        collector.claim(:argument, { scroll: '1m', size: 10 })

        expect(collector.arguments).to eq({ terminate_after: 5, scroll: '1m', size: 10 })
      end

      it 'overwrites an already existing argument' do
        collector.claim(:argument, :terminate_after, 5)
        collector.claim(:argument, :terminate_after, 10)

        expect(collector.arguments).to eq({ terminate_after: 10 })
      end

      it 'keeps the previously claimed arguments' do
        collector.claim(:argument, :a, 1)
        collector.claim(:argument, :b, 2)

        expect(collector.arguments).to eq({ a: 1, b: 2 })
      end

      # PLEASE NOTE: +:arguments+ (plural) REPLACES, +:argument+ (singular) MERGES
      it 'is not the same as the :arguments action' do
        collector.claim(:argument, :a, 1)
        collector.claim(:arguments, { b: 2 })

        expect(collector.arguments).to eq({ b: 2 })
      end
    end

    describe 'action :assign' do
      it 'forwards to the (private) #assign' do
        expect(collector).to receive(:assign).with(:size, 5)

        collector.claim(:assign, :size, 5)
      end

      it 'assigns on the body' do
        collector.claim(:assign, :size, 5)

        expect(collector.body).to eq({ size: 5 })
      end
    end

    it 'raises for an unsupported action' do
      expect { collector.claim(:nope, 1) }.to raise_error(RuntimeError, "Unsupported claim action: nope")
    end

    # PLEASE NOTE: the collector's +claim+ returns the assigned value. Only the VISITOR's +claim+
    # forces a nil return to prevent accidental assignments - so never rely on this return value.
    # see @ Arel::Visitors::ElasticsearchBase#claim
    it 'returns the assigned value' do
      expect(collector.claim(:index, 'my-index')).to eq('my-index')
    end

    describe '#<<' do
      # this is the protocol the visitor uses: +collector << [action, args]+
      it 'splats a provided [action, args] tuple into a claim' do
        collector << [:index, ['my-index']]
        collector << [:assign, [:size, 5]]

        expect(collector.index).to eq('my-index')
        expect(collector.body).to eq({ size: 5 })
      end

      it 'raises for an unsupported action' do
        expect { collector << [:nope, [1]] }.to raise_error(RuntimeError, /Unsupported claim action/)
      end
    end
  end

  # +assign+ is PRIVATE - the visitor never calls it directly, it always claims the +:assign+ action.
  describe '#assign' do
    it 'is a private method' do
      expect(described_class.private_method_defined?(:assign)).to be(true)
    end

    it 'requires exactly a key & a value' do
      expect { collector.claim(:assign, :size) }.to raise_error(ArgumentError, /wrong number of arguments/)
    end

    context 'with a regular key' do
      it 'writes the value into the body' do
        collector.claim(:assign, :size, 5)
        collector.claim(:assign, :from, 10)

        expect(collector.body).to eq({ size: 5, from: 10 })
      end

      # PLEASE NOTE: the collector assigns FLAT - nesting is entirely the visitor's job, which
      # merges sub-assignments into the parent value before claiming it.
      # see @ Arel::Visitors::ElasticsearchBase#assign
      it 'overwrites an existing key without merging' do
        collector.claim(:assign, :query, { bool: { must: [] } })
        collector.claim(:assign, :query, { match_all: {} })

        expect(collector.body).to eq({ query: { match_all: {} } })
      end

      it 'deletes the key for a provided nil value' do
        collector.claim(:assign, :size, 5)
        collector.claim(:assign, :size, nil)

        expect(collector.body).to eq({})
      end

      it 'does not fail for a nil value on an unknown key' do
        expect { collector.claim(:assign, :size, nil) }.not_to raise_error
        expect(collector.body).to eq({})
      end

      # only +nil+ deletes - +false+ is a valid value ('_source: false' disables the source)
      it 'keeps a false value' do
        collector.claim(:assign, :_source, false)

        expect(collector.body).to eq({ _source: false })
      end

      it 'keeps other blank values' do
        collector.claim(:assign, :size, 0)
        collector.claim(:assign, :query, {})

        expect(collector.body).to eq({ size: 0, query: {} })
      end

      # the "key must be a Symbol" guard lives in the VISITOR - the collector writes any key
      it 'does not restrict the key to a Symbol' do
        collector.claim(:assign, 'size', 5)

        expect(collector.body).to eq({ 'size' => 5 })
      end

      # +claim(:body, nil)+ leaves no Hash to assign into
      it 'raises when the body was claimed as nil' do
        collector.claim(:body, nil)

        expect { collector.claim(:assign, :size, 5) }.to raise_error(NoMethodError)
      end

      # the body reader swaps in the +FAILED_BODIES+ - the assigned body is still kept internally
      it 'is shadowed by a failed status' do
        collector.claim(:type, ElasticsearchRecord::Query::TYPE_SEARCH)
        collector.claim(:assign, :size, 5)
        collector.claim(:status, ElasticsearchRecord::Query::STATUS_FAILED)

        expect(collector.body).to eq(ElasticsearchRecord::Query::FAILED_BODIES[ElasticsearchRecord::Query::TYPE_SEARCH])
      end
    end

    # the special key escapes the body and re-dispatches as a claim - this is how query-level
    # (non-body) settings are reached from the relation chain, e.g. +configure(:__query__, refresh: true)+
    # see @ ElasticsearchRecord::Relation::QueryMethods#configure
    context 'with the special :__query__ key' do
      it 'claims the provided Hash key => value' do
        collector.claim(:assign, :__query__, { refresh: true })

        expect(collector.refresh).to be(true)
      end

      it 'does not write anything into the body' do
        collector.claim(:assign, :size, 5)
        collector.claim(:assign, :__query__, { refresh: true })

        expect(collector.body).to eq({ size: 5 })
      end

      it 'claims each Hash of a provided Array' do
        collector.claim(:assign, :__query__, [{ refresh: true }, { timeout: '1m' }])

        expect(collector.refresh).to be(true)
        expect(collector.timeout).to eq('1m')
      end

      it 'claims the provided Array in order' do
        collector.claim(:assign, :__query__, [{ index: 'first' }, { index: 'second' }])

        expect(collector.index).to eq('second')
      end

      it 'reaches the nested :argument action' do
        collector.claim(:assign, :__query__, [{ argument: { terminate_after: 5 } }])

        expect(collector.arguments).to eq({ terminate_after: 5 })
      end

      # +ResultMethods#pit_results+ relies on this to drop the index from a point-in-time query
      # see @ ElasticsearchRecord::Relation::ResultMethods#resolve
      it 'claims a nil value' do
        collector.claim(:index, 'my-index')
        collector.claim(:assign, :__query__, { index: nil })

        expect(collector.index).to be_nil
      end

      # PLEASE NOTE: only the FIRST key of a provided Hash is claimed - the remaining ones are
      # SILENTLY dropped. Use the Array form to claim more than one setting at a time.
      it 'only claims the first key of a provided Hash' do
        collector.claim(:assign, :__query__, { refresh: true, timeout: '1m' })

        expect(collector.refresh).to be(true)
        expect(collector.timeout).to be_nil
      end

      it 'raises for an unsupported nested action' do
        expect {
          collector.claim(:assign, :__query__, { nope: 1 })
        }.to raise_error(RuntimeError, "Unsupported claim action: nope")
      end

      it 'raises for a provided nil - the key cannot be used to delete' do
        expect { collector.claim(:assign, :__query__, nil) }.to raise_error(NoMethodError)
      end

      it 'ignores an empty Array' do
        expect { collector.claim(:assign, :__query__, []) }.not_to raise_error
        expect(collector.body).to eq({})
      end
    end
  end

  # the claimed attributes are what the adapter finally sends to the API
  describe 'the claimed query' do
    it 'builds the API arguments from the claimed attributes' do
      collector.claim(:index, 'my-index')
      collector.claim(:type, ElasticsearchRecord::Query::TYPE_SEARCH)
      collector.claim(:argument, :terminate_after, 5)
      collector.claim(:assign, :size, 5)
      collector.claim(:assign, :__query__, [{ refresh: true }, { timeout: '1m' }])

      expect(collector.query_arguments).to eq({
                                                terminate_after: 5,
                                                index:           'my-index',
                                                body:            { size: 5 },
                                                refresh:         true,
                                                timeout:         '1m'
                                              })
    end

    it 'returns itself as the collected value' do
      expect(collector.value).to equal(collector)
    end
  end
end
