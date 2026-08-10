# frozen_string_literal: true

# Covers every +visit_*+ method of +Arel::Visitors::ElasticsearchSchema+.
#
# The schema visitor is the DDL half of +Arel::Visitors::Elasticsearch+ (the CRUD half lives in
# +Arel::Visitors::ElasticsearchQuery+). It compiles the +*TableDefinition+ objects built by
# +TableStatements#create_table+ / +#change_table+ / +#clone_table+ into an
# +ElasticsearchRecord::Query+ - Elasticsearch has no index-UPDATE API, so a single
# +change_table+ block is decomposed into several mapping / setting / alias queries.
#
# IMPORTANT: the definitions are plain classes (not Arel nodes), so their visits are only reachable
# through the SIMPLE dispatch - which is exactly what +Elasticsearch::SchemaCreation#accept+ sets up.
# Every example therefore compiles through +SchemaCreation+, the same entry point the adapter uses.
#
# PLEASE NOTE: these specs never touch a cluster - constructing the adapter does not connect, and
# the only definition that would read from the server (+CloneTableDefinition+) has its
# +table_settings+ lookup stubbed.
#
# see @ Arel::Visitors::ElasticsearchSchema
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaCreation
RSpec.describe Arel::Visitors::ElasticsearchSchema do
  # short-hand for the definition namespace - a +let+ instead of a constant, so the spec does not
  # leak an +ES+ constant into the global namespace
  let(:es) { ActiveRecord::ConnectionAdapters::Elasticsearch }

  subject(:schema_creation) { es::SchemaCreation.new(adapter) }

  let(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(ElasticsearchSpec::CONFIG.symbolize_keys)
  end

  # the definitions carry no Arel nodes - they are compiled through the simple dispatch
  def compile(definition)
    schema_creation.accept(definition)
  end

  def create_definition(name = 'my-index', **opts)
    es::CreateTableDefinition.new(adapter, name, **opts)
  end

  # +change_table+ wraps every definition into an +InterlacedUpdateTableDefinition+ so the visitor
  # knows which index to talk to - see +UpdateTableDefinition#_exec+
  def update_definition(klass, items, name: 'my-index')
    es::InterlacedUpdateTableDefinition.new(name, klass.new(items))
  end

  def mapping_definition(name, type, **attributes)
    es::TableMappingDefinition.new(name, type, attributes)
  end

  def setting_definition(name, value)
    es::TableSettingDefinition.new(name, value)
  end

  def meta_definition(name, value)
    es::TableMetaDefinition.new(name, value)
  end

  def alias_definition(name, **attributes)
    es::TableAliasDefinition.new(name, attributes)
  end

  #################
  # SCHEMA VISITS #
  #################

  describe '#visit_CreateTableDefinition' do
    it 'claims an index_create type & the index name' do
      query = compile(create_definition)

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_CREATE)
      expect(query.index).to eq('my-index')
    end

    it 'builds an empty body for a definition without any parts' do
      expect(compile(create_definition).body).to eq({})
    end

    it 'builds mappings, settings & aliases in a single body' do
      definition = create_definition
      definition.mapping(:name, :text, fields: { keyword: { type: 'keyword' } })
      definition.mapping(:count, :integer)
      definition.meta(:kind, 'demo')
      definition.setting('number_of_shards', 2)
      definition.add_alias('my-alias', is_write_index: true)

      expect(compile(definition).body).to eq({
                                               mappings: {
                                                 _meta:      { kind: 'demo' },
                                                 properties: {
                                                   name:  { fields: { keyword: { type: 'keyword' } }, type: 'text' },
                                                   count: { type: 'integer' }
                                                 }
                                               },
                                               settings: { 'number_of_shards' => 2 },
                                               aliases:  { :'my-alias' => { is_write_index: true } }
                                             })
    end

    # +_meta+ lives BELOW the mappings node - so metas alone still open it
    it 'opens the mappings node for metas only' do
      definition = create_definition
      definition.meta(:primary_key, 'uuid')

      expect(compile(definition).body).to eq({ mappings: { _meta: { primary_key: 'uuid' } } })
    end

    it 'does not open the mappings node for settings only' do
      definition = create_definition
      definition.setting('number_of_shards', 1)

      expect(compile(definition).body).to eq({ settings: { 'number_of_shards' => 1 } })
    end

    it 'does not open the mappings node for aliases only' do
      definition = create_definition
      definition.add_alias('a')

      expect(compile(definition).body).to eq({ aliases: { a: {} } })
    end

    it 'forwards the body as index & body API arguments' do
      definition = create_definition('other-index')
      definition.setting('number_of_shards', 1)

      expect(compile(definition).query_arguments)
        .to eq({ index: 'other-index', body: { settings: { 'number_of_shards' => 1 } } })
    end
  end

  describe '#visit_CloneTableDefinition' do
    subject(:definition) { es::CloneTableDefinition.new(adapter, 'src-index', 'dst-index') }

    # +CloneTableDefinition+ reads the source settings to carry over the shard defaults
    before { allow(adapter).to receive(:table_settings).and_return({ 'index.number_of_shards' => 3 }) }

    it 'claims an index_clone type & the SOURCE index' do
      query = compile(definition)

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_CLONE)
      expect(query.index).to eq('src-index')
    end

    # the clone target is an API argument - not part of the body
    it 'claims the target as API argument' do
      expect(compile(definition).query_arguments[:target]).to eq('dst-index')
    end

    it 'carries over the resolved default settings' do
      expect(compile(definition).body)
        .to eq({ settings: { 'index.number_of_shards' => 3, 'index.number_of_replicas' => 0 } })
    end

    it 'builds settings & aliases' do
      definition.setting('index.number_of_replicas', 2, force: true)
      definition.alias('my-alias', is_hidden: true)

      expect(compile(definition).body).to eq({
                                               settings: {
                                                 'index.number_of_shards'   => 3,
                                                 'index.number_of_replicas' => 2
                                               },
                                               aliases:  { :'my-alias' => { is_hidden: true } }
                                             })
    end

    # a clone has no mappings - they are inherited from the source index
    it 'never builds a mappings node' do
      expect(compile(definition).body).not_to have_key(:mappings)
    end
  end

  describe '#visit_InterlacedUpdateTableDefinition' do
    # the wrapper only carries the index - the type & body come from the nested definition
    it 'claims the index & delegates to the nested definition' do
      query = compile(update_definition(es::AddMappingDefinition, [mapping_definition(:name, :text)]))

      expect(query.index).to eq('my-index')
      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_MAPPING)
    end
  end

  describe '#visit_ChangeMetaDefinition' do
    it 'claims an index_update_mapping type & assigns the metas' do
      query = compile(update_definition(es::ChangeMetaDefinition, [meta_definition(:primary_key, 'uuid')]))

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_MAPPING)
      expect(query.body).to eq({ _meta: { primary_key: 'uuid' } })
    end

    it 'assigns multiple metas into a single node' do
      items = [meta_definition(:primary_key, 'uuid'), meta_definition(:kind, 'demo')]

      expect(compile(update_definition(es::ChangeMetaDefinition, items)).body)
        .to eq({ _meta: { primary_key: 'uuid', kind: 'demo' } })
    end

    # PLEASE NOTE: +UpdateTableDefinition#remove_meta+ builds a definition with a nil value, and a
    # nested assign DELETES the key for a nil value - which is what removes it from the reloaded
    # +_meta+ node. This is the opposite of a setting (see below).
    # see @ Arel::Visitors::ElasticsearchBase#assign
    it 'drops a meta with a nil value (the remove_meta shape)' do
      items = [meta_definition(:primary_key, 'uuid'), meta_definition(:kind, nil)]

      expect(compile(update_definition(es::ChangeMetaDefinition, items)).body)
        .to eq({ _meta: { primary_key: 'uuid' } })
    end
  end

  describe '#visit_ChangeMappingDefinition' do
    it 'claims an index_update_mapping type & assigns the properties' do
      query = compile(update_definition(es::ChangeMappingDefinition, [mapping_definition(:name, :text)]))

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_MAPPING)
      expect(query.body).to eq({ properties: { name: { type: 'text' } } })
    end

    # +AddMappingDefinition+ is an alias of the very same visit - Elasticsearch has no distinction
    it 'is aliased for an AddMappingDefinition' do
      items = [mapping_definition(:name, :text), mapping_definition(:count, :integer)]
      query = compile(update_definition(es::AddMappingDefinition, items))

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_MAPPING)
      expect(query.body).to eq({ properties: { name: { type: 'text' }, count: { type: 'integer' } } })
    end
  end

  describe '#visit_ChangeSettingDefinition' do
    let(:items) { [setting_definition('index.number_of_replicas', 2)] }

    it 'claims an index_update_setting type' do
      expect(compile(update_definition(es::ChangeSettingDefinition, items)).type)
        .to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_SETTING)
    end

    # settings are written DIRECTLY to the body (no +settings+ node) - the visitor takes the
    # +:__query__+ escape to claim a whole body instead of assigning into it
    # see @ Arel::Collectors::ElasticsearchQuery#assign
    it 'claims the settings as the whole body' do
      expect(compile(update_definition(es::ChangeSettingDefinition, items)).body)
        .to eq({ 'index.number_of_replicas' => 2 })
    end

    it 'assigns multiple settings' do
      items = [setting_definition('index.number_of_replicas', 2), setting_definition('index.refresh_interval', '5s')]

      expect(compile(update_definition(es::ChangeSettingDefinition, items)).body)
        .to eq({ 'index.number_of_replicas' => 2, 'index.refresh_interval' => '5s' })
    end

    %i[AddSettingDefinition RemoveSettingDefinition].each do |klass_name|
      it "is aliased for a #{klass_name}" do
        query = compile(update_definition(es.const_get(klass_name), items))

        expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_SETTING)
        expect(query.body).to eq({ 'index.number_of_replicas' => 2 })
      end
    end

    # PLEASE NOTE: +UpdateTableDefinition#remove_setting+ builds a definition with a nil value, and
    # +visit_TableSettingDefinition+ assigns with +:__force__+ so the nil SURVIVES - Elasticsearch
    # resets a setting to its default when it receives null. This is the opposite of a meta.
    it 'keeps a nil value (the remove_setting shape)' do
      items = [setting_definition('index.refresh_interval', nil)]

      expect(compile(update_definition(es::RemoveSettingDefinition, items)).body)
        .to eq({ 'index.refresh_interval' => nil })
    end
  end

  describe '#visit_ChangeAliasDefinition' do
    # a single alias - NOT a composite definition
    subject(:query) { compile(update_definition(es::ChangeAliasDefinition, alias_definition('my-alias', is_hidden: true))) }

    it 'claims an index_update_alias type' do
      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_ALIAS)
    end

    # the alias name is an API argument, its attributes are the body
    it 'claims the name as API argument & the attributes as body' do
      expect(query.query_arguments)
        .to eq({ name: :'my-alias', index: 'my-index', body: { is_hidden: true } })
    end

    it 'is aliased for an AddAliasDefinition' do
      query = compile(update_definition(es::AddAliasDefinition, alias_definition('my-alias', is_write_index: true)))

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_ALIAS)
      expect(query.body).to eq({ is_write_index: true })
    end
  end

  describe '#visit_RemoveAliasDefinition' do
    subject(:query) do
      compile(update_definition(es::RemoveAliasDefinition, [alias_definition('my-alias'), alias_definition('other')]))
    end

    it 'claims an index_delete_alias type' do
      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_INDEX_DELETE_ALIAS)
    end

    # the delete-alias API takes a comma separated list of names
    it 'joins every alias name into a single argument' do
      expect(query.query_arguments).to eq({ name: 'my-alias,other', index: 'my-index' })
    end

    it 'never builds a body' do
      expect(query.body).to eq({})
    end
  end

  ##############
  # SUB VISITS #
  ##############

  describe '#visit_TableMappings / #visit_TableMappingDefinition' do
    def compile_mapping(name, type, **attributes)
      definition = create_definition
      definition.mapping(name, type, **attributes)

      compile(definition).body.dig(:mappings, :properties, name)
    end

    # the type is resolved through the adapters +type_to_sql+ - the AR type is NOT the ES type
    it 'resolves the AR type through type_to_sql' do
      expect(compile_mapping(:name, :string)).to eq({ type: 'keyword' })
      expect(compile_mapping(:at, :datetime)).to eq({ type: 'date' })
    end

    it 'merges the attributes with the resolved type' do
      expect(compile_mapping(:name, :text, index: false)).to eq({ index: false, type: 'text' })
    end

    # +TableMappingDefinition+ falls back to :object / :nested for a blank type
    it 'falls back to the object type for a mapping with properties but no type' do
      expect(compile_mapping(:obj, nil, properties: { a: { type: 'text' } }))
        .to eq({ properties: { a: { type: 'text' } }, type: 'object' })
    end

    it 'nests every mapping below a single properties node' do
      definition = create_definition
      definition.mapping(:name, :text)
      definition.mapping(:count, :integer)

      expect(compile(definition).body[:mappings][:properties])
        .to eq({ name: { type: 'text' }, count: { type: 'integer' } })
    end
  end

  describe '#visit_TableMetas / #visit_TableMetaDefinition' do
    it 'nests every meta below a single _meta node' do
      definition = create_definition
      definition.meta(:primary_key, 'uuid')
      definition.meta(:auto_increment, 5)

      expect(compile(definition).body[:mappings][:_meta])
        .to eq({ primary_key: 'uuid', auto_increment: 5 })
    end

    # no +:__force__+ here - a nil meta is dropped
    it 'drops a meta with a nil value' do
      definition = create_definition
      definition.meta(:a, nil)
      definition.meta(:b, 'x')

      expect(compile(definition).body[:mappings][:_meta]).to eq({ b: 'x' })
    end
  end

  describe '#visit_TableSettings / #visit_TableSettingDefinition' do
    it 'nests every setting below a single settings node' do
      definition = create_definition
      definition.setting('number_of_shards', 2)
      definition.setting('number_of_replicas', 1)

      expect(compile(definition).body[:settings])
        .to eq({ 'number_of_shards' => 2, 'number_of_replicas' => 1 })
    end

    # +:__force__+ keeps a nil value instead of deleting the key
    it 'keeps a setting with a nil value' do
      definition = create_definition
      definition.setting('refresh_interval', nil)

      expect(compile(definition).body[:settings]).to eq({ 'refresh_interval' => nil })
    end

    # +TableSettingDefinition#initialize+ casts the name to a String - settings keys stay Strings,
    # while mapping / meta / alias keys are Symbols
    it 'keeps the setting name a String' do
      definition = create_definition
      definition.setting(:number_of_shards, 2)

      expect(compile(definition).body[:settings].keys).to eq(%w[number_of_shards])
    end
  end

  describe '#visit_TableAliases / #visit_TableAliasDefinition' do
    it 'nests every alias below a single aliases node' do
      definition = create_definition
      definition.add_alias('a', is_hidden: true)
      definition.add_alias('b')

      expect(compile(definition).body[:aliases]).to eq({ a: { is_hidden: true }, b: {} })
    end

    it 'assigns an empty Hash for an alias without attributes' do
      definition = create_definition
      definition.add_alias('a')

      expect(compile(definition).body[:aliases]).to eq({ a: {} })
    end
  end

  ############
  # DISPATCH #
  ############

  # the definitions are plain classes, so the REGULAR dispatch looks for a fully namespaced
  # +visit_ActiveRecord_ConnectionAdapters_Elasticsearch_*+ method that does not exist. Only the
  # simple dispatch (demodulized class name) reaches these visits - which is the sole reason
  # +SchemaCreation#accept+ wraps the compile into +dispatch_as(:simple)+.
  describe 'dispatch' do
    it 'is unreachable through the regular dispatch' do
      expect { adapter.visitor.compile(create_definition) }
        .to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError,
                        /visit_ActiveRecord_ConnectionAdapters_Elasticsearch_CreateTableDefinition/)
    end

    it 'restores the regular dispatch after the compile' do
      compile(create_definition)

      expect { adapter.visitor.compile(create_definition) }
        .to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError)
    end
  end
end
