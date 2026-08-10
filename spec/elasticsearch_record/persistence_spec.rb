# frozen_string_literal: true

# Covers every method of +ElasticsearchRecord::Persistence::ClassMethods+ (and the instance-level
# +#_create_record+ of the surrounding concern).
#
# These are the three write entry points ActiveRecord calls for a single record. They deliberately
# BYPASS the Arel-builder and send the data directly to the document API - so unlike a relation
# there is no visitor involved and the +ElasticsearchRecord::Query+ is hand-built.
#
# Everything runs against a real index: the +_meta+ round trip of +_insert_with_auto_increment+
# (read the current value -> insert -> write the new value back) cannot be faked meaningfully.
#
# see @ ElasticsearchRecord::Persistence::ClassMethods
RSpec.describe ElasticsearchRecord::Persistence::ClassMethods, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  subject(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'PersistenceSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # +_insert_record+ & +_update_record+ do not receive a plain 'key => value'-Hash, but the
  # +ActiveModel::Attribute+ objects of the record - the CASTED value is resolved from them.
  def attributes_for(hash, klass = model)
    hash.to_h { |name, value|
      [name.to_s, ActiveModel::Attribute.from_user(name.to_s, value, klass.type_for_attribute(name.to_s))]
    }
  end

  # captures the +ElasticsearchRecord::Query+ that is handed to the connection - the query object
  # IS the "SQL" of this adapter, so this is the only way to assert what was built.
  def capture_query(method, klass = model)
    captured = nil

    allow(klass.connection).to receive(method).and_wrap_original do |original, query, *args, **opts|
      captured = query
      original.call(query, *args, **opts)
    end

    yield

    captured
  end

  ##################
  # _INSERT_RECORD #
  ##################

  describe '._insert_record' do
    before { TestIndex.create! }

    after { TestIndex.drop! }

    it 'creates the document' do
      model._insert_record(attributes_for(name: 'alpha', count: 1), nil)

      expect(model.count).to eq(1)
      expect(model.first.name).to eq('alpha')
    end

    it 'builds a create query against the table_name' do
      query = capture_query(:insert) { model._insert_record(attributes_for(name: 'alpha'), nil) }

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_CREATE)
      expect(query.index).to eq(model.table_name)
    end

    # the provided +ActiveModel::Attribute+ objects carry the value BEFORE the type cast - the body
    # must hold the resolved +#value+ of each of them
    it 'resolves the casted value of each provided attribute' do
      values = { 'count' => ActiveModel::Attribute.from_user('count', '42', ActiveRecord::Type::Integer.new) }

      query = capture_query(:insert) { model._insert_record(values, nil) }

      expect(query.body).to eq({ 'count' => 42 })
    end

    # PLEASE NOTE: an elasticsearch field may hold a single value OR an array of them, so EVERY
    # column of this adapter is typed as a +MulticastValue+ - which only casts on +deserialize+ and
    # passes user input straight through. A provided String therefore reaches the index as a String
    # (and is coerced by elasticsearch itself).
    # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue
    it 'does not cast against the column type' do
      query = capture_query(:insert) { model._insert_record(attributes_for(count: '42', active: 'true'), nil) }

      expect(query.body).to eq({ 'count' => '42', 'active' => 'true' })
      expect(model.first.count).to eq(42)
    end

    # a nil attribute is NOT chopped - it must reach the document, so a mapped field is not missing
    it 'keeps a nil value in the body' do
      query = capture_query(:insert) { model._insert_record(attributes_for(name: 'alpha', count: nil), nil) }

      expect(query.body).to eq({ 'name' => 'alpha', 'count' => nil })
    end

    # the +_id+ is a VIRTUAL metadata column - it is the document id and must never be part of the doc
    it 'excludes the _id from the body' do
      query = capture_query(:insert) { model._insert_record(attributes_for(_id: 'a1', name: 'alpha'), nil) }

      expect(query.body).to eq({ 'name' => 'alpha' })
      expect(query.arguments).to eq({ id: 'a1' })
    end

    it 'writes the document under a provided _id' do
      model._insert_record(attributes_for(_id: 'a1', name: 'alpha'), nil)

      expect(model.find_by_id('a1').name).to eq('alpha')
    end

    # without a provided id elasticsearch generates one - the arguments stay empty
    it 'sends no id argument without a provided _id' do
      query = capture_query(:insert) { model._insert_record(attributes_for(name: 'alpha'), nil) }

      expect(query.arguments).to eq({})
      expect(model.first._id).to be_present
    end

    # the refresh is what makes the written document instantly resolvable
    it 'refreshes the index' do
      query = capture_query(:insert) { model._insert_record(attributes_for(name: 'alpha'), nil) }

      expect(query.refresh).to be(true)
      expect(model.count).to eq(1)
    end

    it 'instruments the query with the model name' do
      allow(model.connection).to receive(:insert).and_call_original

      model._insert_record(attributes_for(name: 'alpha'), nil)

      expect(model.connection).to have_received(:insert).with(anything, "#{model} Create", returning: nil)
    end

    # ActiveRecord always provides the primary_key as +returning+ column
    # see @ ActiveRecord::ModelSchema::ClassMethods#_returning_columns_for_insert
    it 'returns the returning column values as an Array' do
      expect(model._insert_record(attributes_for(name: 'alpha'), ['_id'])).to eq([model.first._id])
    end

    it 'returns the plain id without any returning columns' do
      expect(model._insert_record(attributes_for(name: 'alpha'), nil)).to eq(model.first._id)
    end

    # +TYPE_CREATE+ maps to the 'create' operation - it must NOT overwrite an existing document
    it 'raises for an already existing _id' do
      model._insert_record(attributes_for(_id: 'a1', name: 'alpha'), nil)

      expect {
        model._insert_record(attributes_for(_id: 'a1', name: 'again'), nil)
      }.to raise_error(ActiveRecord::RecordNotUnique)

      expect(model.find_by_id('a1').name).to eq('alpha')
    end

    it 'raises for a value the mapping cannot hold' do
      expect {
        model._insert_record(attributes_for(count: 'not-a-number'), nil)
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  ##################
  # _UPDATE_RECORD #
  ##################

  describe '._update_record' do
    before do
      TestIndex.create!

      model._insert_record(attributes_for(_id: 'a1', name: 'alpha', count: 1, active: true), nil)
    end

    after { TestIndex.drop! }

    it 'builds an update query against the table_name' do
      query = capture_query(:update) { model._update_record(attributes_for(count: 5), { '_id' => 'a1' }) }

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_UPDATE)
      expect(query.index).to eq(model.table_name)
    end

    # an update is a PARTIAL document - it has to be nested into a 'doc' node
    it 'nests the resolved values into a doc node' do
      values = { 'count' => ActiveModel::Attribute.from_user('count', '5', ActiveRecord::Type::Integer.new) }

      query = capture_query(:update) { model._update_record(values, { '_id' => 'a1' }) }

      expect(query.body).to eq({ doc: { 'count' => 5 } })
    end

    it 'resolves the id from the constraints of the primary_key' do
      query = capture_query(:update) { model._update_record(attributes_for(count: 5), { '_id' => 'a1' }) }

      expect(query.arguments).to eq({ id: 'a1' })
    end

    it 'only changes the provided attributes' do
      model._update_record(attributes_for(count: 99), { '_id' => 'a1' })

      record = model.find_by_id('a1')
      expect(record.count).to eq(99)
      expect(record.name).to eq('alpha')
    end

    it 'refreshes the index' do
      query = capture_query(:update) { model._update_record(attributes_for(count: 99), { '_id' => 'a1' }) }

      expect(query.refresh).to be(true)
      expect(model.find_by_id('a1').count).to eq(99)
    end

    it 'instruments the query with the model name' do
      allow(model.connection).to receive(:update).and_call_original

      model._update_record(attributes_for(count: 5), { '_id' => 'a1' })

      expect(model.connection).to have_received(:update).with(anything, "#{model} Update")
    end

    # PLEASE NOTE: this documents the CURRENT behaviour. +#exec_update+ resolves the +total+ of the
    # result, but a document-API response carries neither a 'total' nor a 'hits' node - so the
    # "affected rows" of a successful update are always 0.
    # see @ ElasticsearchRecord::Result#_total
    it 'returns 0 instead of the affected rows' do
      expect(model._update_record(attributes_for(count: 5), { '_id' => 'a1' })).to eq(0)
    end

    # ... which does NOT break +#update+ - ActiveRecord only uses the count to decide whether the
    # 'update'-callbacks are triggered.
    it 'does not break a record update' do
      record = model.find_by_id('a1')

      expect(record.update(count: 7)).to be(true)
      expect(model.find_by_id('a1').count).to eq(7)
    end

    it 'raises for an unknown id' do
      expect {
        model._update_record(attributes_for(count: 5), { '_id' => 'nope' })
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  ##################
  # _DELETE_RECORD #
  ##################

  describe '._delete_record' do
    before do
      TestIndex.create!

      model._insert_record(attributes_for(_id: 'a1', name: 'alpha'), nil)
      model._insert_record(attributes_for(_id: 'a2', name: 'beta'), nil)
    end

    after { TestIndex.drop! }

    it 'builds a delete query against the table_name' do
      query = capture_query(:delete) { model._delete_record({ '_id' => 'a1' }) }

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_DELETE)
      expect(query.index).to eq(model.table_name)
    end

    it 'resolves the id from the constraints of the primary_key' do
      query = capture_query(:delete) { model._delete_record({ '_id' => 'a1' }) }

      expect(query.arguments).to eq({ id: 'a1' })
    end

    # a delete carries no data at all
    it 'sends no body' do
      query = capture_query(:delete) { model._delete_record({ '_id' => 'a1' }) }

      expect(query.body).to be_nil
    end

    it 'removes the document' do
      model._delete_record({ '_id' => 'a1' })

      expect(model.count).to eq(1)
      expect(model.first._id).to eq('a2')
    end

    it 'refreshes the index' do
      query = capture_query(:delete) { model._delete_record({ '_id' => 'a1' }) }

      expect(query.refresh).to be(true)
      expect(model.count).to eq(1)
    end

    it 'instruments the query with the model name' do
      allow(model.connection).to receive(:delete).and_call_original

      model._delete_record({ '_id' => 'a1' })

      expect(model.connection).to have_received(:delete).with(anything, "#{model} Delete")
    end

    # see the note at +._update_record+ - a document-API response has no 'total' node
    it 'returns 0 instead of the affected rows' do
      expect(model._delete_record({ '_id' => 'a1' })).to eq(0)
    end

    it 'does not break a record destroy' do
      record = model.find_by_id('a1')

      record.destroy

      expect(record).to be_destroyed
      expect(model.count).to eq(1)
    end

    it 'raises for an unknown id' do
      expect { model._delete_record({ '_id' => 'nope' }) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  ###############################
  # _INSERT_WITH_AUTO_INCREMENT #
  ###############################

  # The +auto_increment+ is NOT an elasticsearch feature - it is emulated through the +_meta+ node of
  # the index mappings, which +TestIndexWithAutoIncrement+ creates:
  #
  #   create_table "settings", force: true do |t|
  #     t.mapping :created_at, :date
  #     t.mapping :key, :integer do |m|
  #       m.primary_key   = true
  #       m.auto_increment = 10
  #     end
  #   end
  #
  # A mapping flagged as +primary_key+ writes a '_meta.primary_key' - and, with an additionally
  # provided +auto_increment+, a '_meta.auto_increment' holding the START value.
  # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::CreateTableDefinition#mapping
  # see @ TestIndexWithAutoIncrement
  describe '._insert_with_auto_increment' do
    subject(:settings) { TestIndexWithAutoIncrement.model('PersistenceSettingsSpecModel') }

    before { TestIndexWithAutoIncrement.create! }

    after { TestIndexWithAutoIncrement.drop! }

    # yields the resolved arguments & returns them, so the RESOLUTION can be asserted without a write
    def resolve_arguments(klass = settings, values = {})
      klass.send(:_insert_with_auto_increment, values) { |arguments| arguments }
    end

    describe 'the schema it rests on' do
      it 'stores the primary_key & the auto_increment within the _meta' do
        expect(TestIndexWithAutoIncrement.metas).to eq({ 'primary_key' => 'key', 'auto_increment' => 10 })
      end

      it 'resolves the flagged mapping as primary_key' do
        expect(settings.primary_key).to eq('key')
      end

      it 'resolves the auto_increment status from the _meta' do
        expect(settings.auto_increment?).to be(true)
      end
    end

    context 'with a provided primary_key value' do
      it 'yields the provided value as id' do
        expect(resolve_arguments(settings, { 'key' => 55 })).to eq({ id: 55 })
      end

      # the +_meta+ is only maintained by the auto_increment branch - a manually provided id
      # deliberately leaves it alone
      it 'does not touch the auto_increment meta' do
        settings.create!(key: 55)

        expect(TestIndexWithAutoIncrement.auto_increment).to eq(10)
      end

      it 'writes the document under the provided id' do
        settings.create!(key: 55)

        expect(settings.find_by_id(55).key).to eq(55)
      end
    end

    # This is the END-TO-END path: a plain +create+ has to hand out the next id AND leave a usable
    # '_meta.auto_increment' behind - a broken write-back only surfaces on the NEXT insert.
    context 'with an auto_increment' do
      it 'starts at the auto_increment of the schema' do
        expect(TestIndexWithAutoIncrement.auto_increment).to eq(TestIndexWithAutoIncrement::START)
      end

      it 'resolves the next id for a created record' do
        expect(settings.create!(created_at: Time.now).key).to eq(11)
      end

      it 'writes the resolved id back into the auto_increment meta' do
        settings.create!(created_at: Time.now)

        expect(TestIndexWithAutoIncrement.auto_increment).to eq(11)
      end

      # PLEASE NOTE: the meta is created as an INTEGER and must stay one. Elasticsearch resolves a
      # document +_id+ as String, so the raw insert result would flip the type of the schema behind
      # the first create.
      it 'keeps the auto_increment meta an Integer' do
        settings.create!(created_at: Time.now)

        expect(TestIndexWithAutoIncrement.auto_increment).to be_a(Integer)
      end

      it 'leaves the primary_key meta untouched' do
        settings.create!(created_at: Time.now)

        expect(TestIndexWithAutoIncrement.metas['primary_key']).to eq('key')
      end

      it 'increments with every created record' do
        3.times { settings.create!(created_at: Time.now) }

        expect(settings.all.map(&:_id)).to match_array(%w[11 12 13])
        expect(TestIndexWithAutoIncrement.auto_increment).to eq(13)
      end

      it 'starts at a different auto_increment of the schema' do
        TestIndexWithAutoIncrement.create!(500)

        expect(settings.create!(created_at: Time.now).key).to eq(501)
        expect(TestIndexWithAutoIncrement.auto_increment).to eq(501)
      end
    end

    context 'without a provided primary_key value' do
      it 'yields the auto_increment meta increased by one' do
        expect(resolve_arguments).to eq({ id: 11 })
      end

      # +connection.insert+ does NOT resolve a plain id: ActiveRecord always provides the primary_key
      # as +returning+ column, so an ARRAY of the returning column values is resolved. The +_meta+
      # must be updated with the PLAIN id - the raw result would break the +.to_i+ of the NEXT insert.
      # see @ ActiveRecord::Persistence#_create_record
      it 'writes the first value of a returning Array into the meta' do
        settings.send(:_insert_with_auto_increment, {}) { |_arguments| ['77'] }

        expect(TestIndexWithAutoIncrement.auto_increment).to eq(77)
      end

      # a provided block may also resolve the +arguments+ Hash it was called with
      it 'writes the id of a returning Hash into the meta' do
        expect(TestIndexWithAutoIncrement.auto_increment).to eq(10)

        settings.send(:_insert_with_auto_increment, {}) { |arguments|
          # check the AutoIncrement value
          expect(arguments).to eq({ id: 11 })

          arguments
        }

        expect(TestIndexWithAutoIncrement.auto_increment).to eq(11)
      end

      it 'also accepts a plain id from the block' do
        settings.send(:_insert_with_auto_increment, {}) { |_arguments| '77' }

        expect(TestIndexWithAutoIncrement.auto_increment).to eq(77)
      end

      it 'returns the block result unchanged' do
        expect(settings.send(:_insert_with_auto_increment, {}) { |_arguments| ['77'] }).to eq(['77'])
      end

      it 'does not touch the meta if the block resolved no id' do
        settings.send(:_insert_with_auto_increment, {}) { |_arguments| nil }

        expect(TestIndexWithAutoIncrement.auto_increment).to eq(10)
      end

      # for secure reasons the CURRENT maximum of the primary key is resolved as well - a manually
      # provided, higher id must not be handed out a second time
      it 'resolves the maximum of the primary key if it exceeds the meta' do
        settings.create!(key: 99)
        settings.api.refresh!

        expect(resolve_arguments).to eq({ id: 100 })
      end

      it 'keeps the meta value if it exceeds the maximum of the primary key' do
        settings.create!(key: 5)
        settings.api.refresh!

        expect(resolve_arguments).to eq({ id: 11 })
      end

      it 'continues at the auto_increment meta after a manually provided id' do
        settings.create!(key: 99)
        settings.api.refresh!
        settings.create!(created_at: Time.now)

        expect(TestIndexWithAutoIncrement.auto_increment).to eq(100)
      end

      # PLEASE NOTE: ActiveRecord chops a nil primary_key from the attributes of a create, so the
      # resolved id is ONLY written as document +_id+ - the mapped 'key' field stays absent in the
      # +_source+. It is written back into the record IN MEMORY (through the returning column), but
      # a reloaded record resolves a nil 'key' and +find+ (which queries the 'key' field) misses it.
      # see @ ActiveRecord::Persistence#attributes_for_create
      it 'does not store the resolved id within the document' do
        record = settings.create!(created_at: Time.now)

        expect(record.key).to eq(11)
        expect(settings.all.hits['hits'].first['_source']).not_to have_key('key')
        expect(settings.first.key).to be_nil
      end

      it 'resolves the record through its _id' do
        settings.create!(created_at: Time.now)

        expect(settings.find_by_id(11)).to be_present
        expect { settings.find(11) }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'without an auto_increment' do
      before { TestIndex.create! }

      after { TestIndex.drop! }

      it 'yields empty arguments' do
        expect(resolve_arguments(model)).to eq({})
      end

      # the default test index carries no '_meta' at all - so there is nothing to resolve an id from
      it 'carries no auto_increment meta' do
        expect(model.connection.table_metas(model.index_name)['auto_increment']).to be_nil
        expect(model.auto_increment?).to be(false)
      end

      it 'lets elasticsearch generate the id' do
        model.create!(name: 'alpha')

        expect(model.first._id).to be_present
      end

      # the meta stays absent - the branch must not create one
      it 'does not write an auto_increment meta' do
        model.create!(name: 'alpha')

        expect(model.connection.table_metas(model.index_name)).to eq({})
      end

      it 'still yields a provided primary_key value as id' do
        expect(resolve_arguments(model, { '_id' => 'a1' })).to eq({ id: 'a1' })
      end
    end
  end

  ##################
  # _CREATE_RECORD #
  ##################

  # The INSTANCE-level +#_create_record+ of the concern - it only wraps the ActiveRecord original
  # into +#undelegate_id_attribute_with+, since a lot of rails-code forces the primary_key access
  # through the +#id+ getter & setter, which would otherwise write the 'id'-ATTRIBUTE.
  # see @ ElasticsearchRecord::Core#undelegate_id_attribute_with
  describe '#_create_record' do
    let(:index_name) { "#{TestIndex.name}_ids" }

    subject(:id_model) do
      Class.new(ElasticsearchRecord::Base) {
        def self.name = 'PersistenceIdSpecModel'

        self.delegate_id_attribute = true
      }.tap { |klass|
        klass.table_name = index_name
        klass.reset_column_information
      }
    end

    before do
      TestIndex.create!(index_name) do |t|
        t.mapping :id, :keyword
        t.mapping :name, :keyword
      end
    end

    after { TestIndex.drop!(index_name) }

    it 'disables the id attribute delegation during the insert' do
      observed = []
      id_model.before_create { |record| observed << record.delegate_id_attribute? }

      id_model.create!(id: 'custom-1', name: 'alpha')

      expect(observed).to eq([false])
    end

    it 'restores the id attribute delegation afterwards' do
      record = id_model.create!(id: 'custom-1', name: 'alpha')

      expect(record.delegate_id_attribute?).to be(true)
    end

    # the 'id'-attribute is a REGULAR field of the document - it must not become the document +_id+
    it 'stores the id attribute within the document' do
      id_model.create!(id: 'custom-1', name: 'alpha')

      expect(id_model.find_by_id('custom-1').name).to eq('alpha')
      expect(id_model.first._id).not_to eq('custom-1')
    end

    it 'resolves the id attribute through #id' do
      expect(id_model.create!(id: 'custom-1', name: 'alpha').id).to eq('custom-1')
    end

    # without an active delegation the block is called straight through
    it 'does not touch a model without the delegation' do
      TestIndex.create!

      observed = []
      model.before_create { |record| observed << record.delegate_id_attribute? }

      model.create!(name: 'alpha')

      expect(observed).to eq([false])
    ensure
      TestIndex.drop!
    end
  end
end
