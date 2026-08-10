# frozen_string_literal: true

# Covers every method of +ElasticsearchRecord::ModelApi+ (+Model.api+).
#
# The class is the DIRECT index-manipulation surface: it bypasses the relation / Arel pipeline
# completely and talks to the adapter (and through it to the elasticsearch-api client) right away.
# Almost all of its methods are generated - the four generator loops each follow a different
# delegation rule, which is what the first half of this file pins.
#
# The examples are split in two:
# - the delegation itself, against a fully stubbed model & connection (no cluster)
# - the actual behaviour of the bulk & table shortcuts against a real index
#
# see @ ElasticsearchRecord::ModelApi
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::TableStatements
RSpec.describe ElasticsearchRecord::ModelApi do
  ##############
  # DELEGATION #
  ##############

  describe 'the delegated methods' do
    subject(:api) { described_class.new(klass) }

    # a verifying double: every delegation target must really exist on the adapter
    let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter) }

    let(:klass) { double('MyModel', index_name: 'my-index', connection: connection) }

    it 'exposes the provided klass' do
      expect(api.klass).to be(klass)
    end

    # generator 1: no arguments at all - the defaults of the underlying method are always used
    describe 'the dangerous methods without arguments' do
      %w[open close refresh block unblock].each do |method|
        it "##{method}! forwards the index name to ##{method}_table" do
          allow(connection).to receive("#{method}_table").and_return(true)

          expect(api.public_send("#{method}!")).to be(true)
          expect(connection).to have_received("#{method}_table").with('my-index')
        end

        # the generated method takes NO arguments - +block!(:read)+ is not possible
        it "##{method}! accepts no arguments" do
          expect(api.method("#{method}!").arity).to eq(0)
        end
      end
    end

    # generator 2: the index name is prepended, everything else is passed straight through.
    # PLEASE NOTE: the arguments below mirror the real +*_table+ signatures - the verifying double
    # rejects anything else, which is exactly what keeps this pinned to the adapter.
    describe 'the dangerous methods with arguments' do
      {
        create:  [{ force: true }],
        clone:   ['target-index'],
        rename:  ['target-index'],
        backup:  [{ to: 'backup-index' }],
        restore: [{ from: 'backup-index' }],
        reindex: ['target-index']
      }.each do |method, args|
        it "##{method}! prepends the index name to ##{method}_table" do
          allow(connection).to receive("#{method}_table").and_return(true)

          expect(api.public_send("#{method}!", *args)).to be(true)
          expect(connection).to have_received("#{method}_table").with('my-index', *args)
        end
      end
    end

    # generator 3: destructive & irreversible - they refuse to run unconfirmed
    describe 'the confirm guarded methods' do
      %w[drop truncate].each do |method|
        describe "##{method}!" do
          it 'raises without a confirmation' do
            expect { api.public_send("#{method}!") }
              .to raise_error(RuntimeError, /#{method} of table 'my-index' aborted!/)
          end

          it 'raises for an explicit confirm: false' do
            expect { api.public_send("#{method}!", confirm: false) }.to raise_error(RuntimeError)
          end

          # the guard must fire BEFORE the connection is touched
          it 'does not touch the connection without a confirmation' do
            allow(connection).to receive("#{method}_table")

            expect { api.public_send("#{method}!") }.to raise_error(RuntimeError)
            expect(connection).not_to have_received("#{method}_table")
          end

          it 'points to the confirmed call in the message' do
            expect { api.public_send("#{method}!") }
              .to raise_error(/call with: .*\.api\.#{method}!\(confirm: true\)/)
          end

          it 'forwards to the connection with a confirmation' do
            allow(connection).to receive("#{method}_table").and_return(true)

            expect(api.public_send("#{method}!", confirm: true)).to be(true)
            expect(connection).to have_received("#{method}_table").with('my-index')
          end
        end
      end
    end

    # generator 4: the connection method carries a 'table_' prefix
    describe 'the table shortcuts' do
      %w[mappings metas settings aliases state schema].each do |method|
        it "##{method} forwards to #table_#{method}" do
          allow(connection).to receive("table_#{method}").and_return({})

          expect(api.public_send(method)).to eq({})
          expect(connection).to have_received("table_#{method}").with('my-index')
        end
      end

      # only these two take a second argument - the others are index-name only
      it '#settings passes the flat_settings flag through' do
        allow(connection).to receive(:table_settings).and_return({})

        api.settings(false)

        expect(connection).to have_received(:table_settings).with('my-index', false)
      end

      it '#schema passes the features through' do
        allow(connection).to receive(:table_schema).and_return({})

        api.schema([:mappings])

        expect(connection).to have_received(:table_schema).with('my-index', [:mappings])
      end

      # the question mark is part of the name on BOTH sides
      it '#exists? forwards to #table_exists?' do
        allow(connection).to receive(:table_exists?).and_return(true)

        expect(api.exists?).to be(true)
        expect(connection).to have_received(:table_exists?).with('my-index')
      end
    end

    # generator 5: same name on both sides - only the index name is prepended
    describe 'the plain shortcuts' do
      %w[alias_exists? setting_exists? mapping_exists? meta_exists?].each do |method|
        it "##{method} prepends the index name" do
          allow(connection).to receive(method).and_return(true)

          expect(api.public_send(method, 'some-name')).to be(true)
          expect(connection).to have_received(method).with('my-index', 'some-name')
        end
      end

      # +mapping_exists?+ additionally accepts a type
      it '#mapping_exists? passes a provided type through' do
        allow(connection).to receive(:mapping_exists?).and_return(true)

        api.mapping_exists?(:count, :integer)

        expect(connection).to have_received(:mapping_exists?).with('my-index', :count, :integer)
      end
    end
  end

  ########
  # BULK #
  ########

  describe 'the bulk methods' do
    subject(:api) { described_class.new(klass) }

    let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter) }

    let(:klass) { double('MyModel', index_name: 'my-index', connection: connection) }

    # captures the arguments the bulk API was called with
    def capture_bulk
      captured = nil
      allow(connection).to receive(:api) do |_gate, arguments, name, **options|
        captured = { arguments: arguments, name: name, options: options }
        {}
      end

      yield

      captured
    end

    describe '#bulk' do
      it 'calls the bulk gate with the index & a refresh' do
        captured = capture_bulk { api.bulk({ name: 'a' }) }

        expect(captured[:arguments][:index]).to eq('my-index')
        expect(captured[:arguments][:refresh]).to be(true)
      end

      it 'wraps a single Hash into an Array' do
        captured = capture_bulk { api.bulk({ name: 'a' }) }

        expect(captured[:arguments][:body]).to eq([{ index: { _id: nil, data: { name: 'a' } } }])
      end

      it 'defaults to the :index operation' do
        captured = capture_bulk { api.bulk({ name: 'a' }) }

        expect(captured[:name]).to eq('BULK INDEX')
      end

      it 'names the instrumentation after the operation' do
        expect(capture_bulk { api.bulk({ name: 'a' }, :create) }[:name]).to eq('BULK CREATE')
      end

      it 'accepts an explicit refresh' do
        expect(capture_bulk { api.bulk({ name: 'a' }, :index, refresh: false) }[:arguments][:refresh]).to be(false)
      end

      # everything that is not the refresh is forwarded as API options.
      # PLEASE NOTE: +#api+ only accepts +async+, +allow_retry+ & +materialize_transactions+ - any
      # other option raises, so these "options" are not a free-form Hash.
      # see @ ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#api
      it 'forwards additional options to the api call' do
        expect(capture_bulk { api.bulk({ name: 'a' }, :index, allow_retry: true) }[:options])
          .to eq({ allow_retry: true })
      end

      # IMPORTANT: the doc id must be provided WITH the underscore
      it 'chops the _id out of the data' do
        captured = capture_bulk { api.bulk({ _id: 5, name: 'a' }) }

        expect(captured[:arguments][:body]).to eq([{ index: { _id: 5, data: { name: 'a' } } }])
      end

      it 'also accepts a String _id key' do
        captured = capture_bulk { api.bulk({ '_id' => 5, 'name' => 'a' }) }

        expect(captured[:arguments][:body]).to eq([{ index: { _id: 5, data: { 'name' => 'a' } } }])
      end

      # an update is a PARTIAL document - it has to be nested into a 'doc' node
      it 'nests the data into a doc node for an update' do
        captured = capture_bulk { api.bulk({ _id: 5, name: 'a' }, :update) }

        expect(captured[:arguments][:body]).to eq([{ update: { _id: 5, data: { doc: { name: 'a' } } } }])
      end

      # a delete carries no data at all
      it 'sends only the _id for a delete' do
        captured = capture_bulk { api.bulk({ _id: 5, name: 'a' }, :delete) }

        expect(captured[:arguments][:body]).to eq([{ delete: { _id: 5 } }])
      end

      it 'builds one body entry per provided Hash' do
        captured = capture_bulk { api.bulk([{ _id: 1, name: 'a' }, { _id: 2, name: 'b' }]) }

        expect(captured[:arguments][:body]).to eq([{ index: { _id: 1, data: { name: 'a' } } },
                                                   { index: { _id: 2, data: { name: 'b' } } }])
      end
    end

    describe '#index' do
      it 'bulks with the :index operation' do
        expect(capture_bulk { api.index({ name: 'a' }) }[:name]).to eq('BULK INDEX')
      end

      it 'forwards the options' do
        expect(capture_bulk { api.index({ name: 'a' }, refresh: false) }[:arguments][:refresh]).to be(false)
      end
    end

    describe '#insert' do
      it 'bulks with the :create operation' do
        expect(capture_bulk { api.insert({ name: 'a' }) }[:name]).to eq('BULK CREATE')
      end
    end

    describe '#update' do
      it 'bulks with the :update operation' do
        expect(capture_bulk { api.update({ _id: 1, name: 'a' }) }[:name]).to eq('BULK UPDATE')
      end
    end

    describe '#delete' do
      it 'bulks with the :delete operation' do
        expect(capture_bulk { api.delete(1) }[:name]).to eq('BULK DELETE')
      end

      # a plain id is wrapped into the {_id: ...} shape
      it 'accepts a single id' do
        expect(capture_bulk { api.delete(7) }[:arguments][:body]).to eq([{ delete: { _id: 7 } }])
      end

      it 'accepts an Array of ids' do
        expect(capture_bulk { api.delete([1, 2]) }[:arguments][:body])
          .to eq([{ delete: { _id: 1 } }, { delete: { _id: 2 } }])
      end

      it 'accepts a single Hash' do
        expect(capture_bulk { api.delete({ _id: 9 }) }[:arguments][:body]).to eq([{ delete: { _id: 9 } }])
      end

      it 'accepts an Array of Hashes' do
        expect(capture_bulk { api.delete([{ _id: 1 }, { _id: 2 }]) }[:arguments][:body])
          .to eq([{ delete: { _id: 1 } }, { delete: { _id: 2 } }])
      end

      # PLEASE NOTE: the shape is decided by the FIRST element only
      it 'decides the shape by the first element' do
        expect(capture_bulk { api.delete(['a', 'b']) }[:arguments][:body])
          .to eq([{ delete: { _id: 'a' } }, { delete: { _id: 'b' } }])
      end
    end
  end

  ##########################
  # AGAINST A REAL INDEX   #
  ##########################

  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  context 'against a real index', :elasticsearch do
    subject(:api) { model.api }

    let(:model) do
      Class.new(ElasticsearchRecord::Base) {
        def self.name = 'ModelApiSpecModel'
      }.tap { |klass|
        klass.table_name = TestIndex.name
        klass.reset_column_information
      }
    end

    before { TestIndex.create! }

    after { TestIndex.drop! }

    it 'is exposed through the model' do
      expect(model.api).to be_a(described_class)
      expect(model.api.klass).to be(model)
    end

    describe 'the table shortcuts' do
      it '#exists? is true for the created index' do
        expect(api.exists?).to be(true)
      end

      it '#mappings returns the properties' do
        expect(api.mappings['properties'].keys).to match_array(%w[name count active created_at])
      end

      it '#metas returns an empty Hash without any meta' do
        expect(api.metas).to eq({})
      end

      it '#settings returns the flat settings' do
        expect(api.settings['index.number_of_shards']).to eq('1')
      end

      # the argument is forwarded - +settings(false)+ resolves the NESTED form
      it '#settings forwards the flat_settings flag' do
        expect(api.settings(false).dig('index', 'number_of_shards')).to eq('1')
      end

      it '#aliases returns an empty Hash without any alias' do
        expect(api.aliases).to eq({})
      end

      it '#state returns the index state' do
        expect(api.state[:name]).to eq(TestIndex.name)
        expect(api.state[:status]).to eq('open')
      end

      it '#schema returns settings, mappings & aliases' do
        expect(api.schema.keys).to eq(%i[settings mappings aliases])
      end
    end

    describe 'the plain shortcuts' do
      it '#mapping_exists? resolves an existing mapping' do
        expect(api.mapping_exists?(:name)).to be(true)
        expect(api.mapping_exists?(:nope)).to be(false)
      end

      # PLEASE NOTE: the type is the ACTIVERECORD type of the column - not the elasticsearch
      # mapping type. A 'keyword' mapping is a :string column.
      it '#mapping_exists? checks against the ActiveRecord type' do
        expect(api.mapping_exists?(:name, :string)).to be(true)
        expect(api.mapping_exists?(:name, :keyword)).to be(false)
      end

      it '#setting_exists? resolves a flat setting name' do
        expect(api.setting_exists?('index.number_of_shards')).to be(true)
        expect(api.setting_exists?('number_of_shards')).to be(false)
      end

      it '#alias_exists? is false without any alias' do
        expect(api.alias_exists?('nope')).to be(false)
      end

      it '#meta_exists? is false without any meta' do
        expect(api.meta_exists?('nope')).to be(false)
      end
    end

    describe 'the index state methods' do
      it '#close! and #open! toggle the index status' do
        api.close!
        expect(api.state[:status]).to eq('close')

        api.open!
        expect(api.state[:status]).to eq('open')
      end

      # a closed index still EXISTS - the lookup expands to closed indices
      it 'keeps a closed index resolvable' do
        api.close!

        expect(api.exists?).to be(true)
      ensure
        api.open!
      end

      it '#refresh! makes written documents resolvable' do
        api.bulk({ _id: 'r1', name: 'a' }, :index, refresh: false)
        api.refresh!

        expect(model.count).to eq(1)
      end

      it '#block! and #unblock! toggle the write block' do
        expect(api.block!).to be(true)

        expect { model.create!(name: 'blocked') }.to raise_error(ActiveRecord::StatementInvalid)

        api.unblock!
        expect { model.create!(name: 'unblocked') }.not_to raise_error
      end
    end

    describe 'the confirm guarded methods' do
      it '#drop! removes the index when confirmed' do
        api.drop!(confirm: true)

        expect(model.connection.table_exists?(TestIndex.name)).to be(false)
      end

      it '#drop! leaves the index untouched without a confirmation' do
        expect { api.drop! }.to raise_error(RuntimeError)
        expect(api.exists?).to be(true)
      end

      it '#truncate! empties the index when confirmed' do
        api.index([{ name: 'a' }, { name: 'b' }])
        expect(model.count).to eq(2)

        api.truncate!(confirm: true)

        expect(model.count).to eq(0)
        expect(api.exists?).to be(true)
      end
    end

    describe 'the write methods' do
      it '#index writes the provided documents' do
        api.index([{ _id: 'a1', name: 'alpha', count: 1 }, { _id: 'a2', name: 'beta', count: 2 }])

        expect(model.count).to eq(2)
        expect(model.find('a1').name).to eq('alpha')
      end

      it '#index overwrites an already existing document' do
        api.index({ _id: 'a1', name: 'alpha' })
        api.index({ _id: 'a1', name: 'changed' })

        expect(model.find('a1').name).to eq('changed')
      end

      it '#index generates an id when none was provided' do
        api.index({ name: 'alpha' })

        expect(model.first._id).to be_present
      end

      # +insert+ uses the 'create' operation - it must NOT overwrite
      it '#insert reports an error for an already existing id' do
        api.insert({ _id: 'a1', name: 'alpha' })
        response = api.insert({ _id: 'a1', name: 'again' })

        expect(response['errors']).to be(true)
        expect(model.find('a1').name).to eq('alpha')
      end

      # an update is PARTIAL - untouched attributes survive
      it '#update only changes the provided attributes' do
        api.index({ _id: 'a1', name: 'alpha', count: 1 })
        api.update({ _id: 'a1', count: 99 })

        record = model.find('a1')
        expect(record.count).to eq(99)
        expect(record.name).to eq('alpha')
      end

      it '#delete removes a document by its id' do
        api.index([{ _id: 'a1', name: 'alpha' }, { _id: 'a2', name: 'beta' }])
        api.delete('a1')

        expect(model.count).to eq(1)
        expect(model.first._id).to eq('a2')
      end

      it '#delete removes multiple documents' do
        api.index([{ _id: 'a1', name: 'alpha' }, { _id: 'a2', name: 'beta' }])
        api.delete(%w[a1 a2])

        expect(model.count).to eq(0)
      end

      # the refresh is what makes a written document instantly resolvable
      it 'refreshes by default' do
        api.index({ _id: 'a1', name: 'alpha' })

        expect(model.count).to eq(1)
      end

      it 'does not refresh with refresh: false' do
        api.index({ _id: 'a1', name: 'alpha' }, refresh: false)

        expect(model.count).to eq(0)
      end
    end

    describe '#clone!' do
      let(:clone_name) { "#{TestIndex.name}_clone" }

      # a clone requires a write-blocked source index
      before { api.block! }

      after { TestIndex.drop!(clone_name) }

      it 'creates the target index' do
        api.clone!(clone_name)

        expect(model.connection.table_exists?(clone_name)).to be(true)
      end
    end
  end
end
