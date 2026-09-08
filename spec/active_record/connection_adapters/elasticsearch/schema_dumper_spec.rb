# frozen_string_literal: true

# Covers +ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper+.
#
# The dumper turns a live index back into the +create_table+ block of a schema file. It replaces
# ActiveRecord's column-centric output with the four Elasticsearch nodes (metas, aliases, mappings
# & settings) and additionally restricts WHICH indices are dumped at all - a connection carrying a
# +table_name_prefix+ / +table_name_suffix+ must not dump the indices of another environment.
#
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper do
  # short-hand for the namespace - a +let+ instead of a constant, so the spec does not leak
  let(:es) { ActiveRecord::ConnectionAdapters::Elasticsearch }

  # a plain adapter is enough for everything that does not read an index
  let(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(ElasticsearchSpec::CONFIG.symbolize_keys)
  end

  # the adapter builds the dumper - +#create_schema_dumper+ is its factory
  subject(:dumper) { adapter.create_schema_dumper({}) }

  #####################
  # WITHOUT A CLUSTER #
  #####################

  it 'is built by the adapter' do
    expect(adapter.create_schema_dumper({})).to be_a(described_class)
  end

  describe 'the expanded options' do
    # the prefix & suffix are taken from the CONNECTION config, not from ActiveRecord::Base
    it 'defaults to the connection prefix & suffix' do
      options = dumper.instance_variable_get(:@options)

      expect(options[:table_name_prefix]).to eq('')
      expect(options[:table_name_suffix]).to eq('')
    end

    context 'with a configured prefix & suffix' do
      let(:adapter) do
        ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
          ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: 'pre-', table_name_suffix: '-dev'))
      end

      it 'adopts them from the connection' do
        options = dumper.instance_variable_get(:@options)

        expect(options[:table_name_prefix]).to eq('pre-')
        expect(options[:table_name_suffix]).to eq('-dev')
      end
    end

    # only a BLANK option is filled in - an explicitly provided one wins
    it 'keeps an explicitly provided option' do
      options = adapter.create_schema_dumper({ table_name_prefix: 'explicit-' })
                       .instance_variable_get(:@options)

      expect(options[:table_name_prefix]).to eq('explicit-')
    end
  end

  describe '#_has_env_table_names?' do
    it 'is false without a prefix & suffix' do
      expect(dumper.send(:_has_env_table_names?)).to be(false)
    end

    context 'with a configured prefix' do
      let(:adapter) do
        ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
          ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: 'pre-'))
      end

      it 'is true' do
        expect(dumper.send(:_has_env_table_names?)).to be(true)
      end
    end
  end

  # THE reason this class overwrites +ignored?+: without the restriction a dump would also contain
  # the indices of every other environment on the same cluster
  describe '#ignored_table?' do
    it 'ignores nothing without a prefix & suffix' do
      expect(dumper.send(:ignored_table?, 'whatever')).to be(false)
    end

    context 'with a configured prefix & suffix' do
      let(:adapter) do
        ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
          ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: 'pre-', table_name_suffix: '-dev'))
      end

      it 'keeps a matching table' do
        expect(dumper.send(:ignored_table?, 'pre-foo-dev')).to be(false)
      end

      it 'ignores a table without the prefix' do
        expect(dumper.send(:ignored_table?, 'foo-dev')).to be(true)
      end

      it 'ignores a table without the suffix' do
        expect(dumper.send(:ignored_table?, 'pre-foo')).to be(true)
      end
    end
  end

  describe '#ignored?' do
    # the ActiveRecord-internal tables stay ignored
    it 'still ignores the ActiveRecord internal tables' do
      expect(dumper.send(:ignored?, 'schema_migrations')).to be(true)
      expect(dumper.send(:ignored?, 'ar_internal_metadata')).to be(true)
    end

    it 'keeps a regular table' do
      expect(dumper.send(:ignored?, 'my-index')).to be(false)
    end

    context 'with a configured prefix' do
      let(:adapter) do
        ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
          ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: 'pre-'))
      end

      it 'additionally ignores a non-matching table' do
        expect(dumper.send(:ignored?, 'other-index')).to be(true)
        expect(dumper.send(:ignored?, 'pre-index')).to be(false)
      end
    end
  end

  # turns a ruby value back into the source it was written as
  describe '#format_attribute' do
    {
      1        => '1',
      'a'      => '"a"',
      :sym     => ':sym',
      nil      => 'nil',
      true     => 'true',
      [1, 'b'] => '[1, "b"]'
    }.each do |value, expected|
      it "formats #{value.inspect} as #{expected}" do
        expect(dumper.send(:format_attribute, value)).to eq(expected)
      end
    end

    # a top-level Hash becomes a keyword ARGUMENT list - without the braces
    it 'formats a Hash as a keyword argument list' do
      expect(dumper.send(:format_attribute, { a: 1, b: 'x' })).to eq('a: 1, b: "x"')
    end

    # ... while a nested Hash keeps its braces
    it 'wraps a nested Hash in braces' do
      expect(dumper.send(:format_attribute, { a: 1 }, true)).to eq('{ a: 1 }')
    end

    it 'wraps every nested level' do
      expect(dumper.send(:format_attribute, { a: { b: 2 } })).to eq('a: { b: 2 }')
    end

    it 'formats a Hash within an Array' do
      expect(dumper.send(:format_attribute, [{ a: 1 }])).to eq('[a: 1]')
    end
  end

  ########################
  # AGAINST A REAL INDEX #
  ########################

  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  context 'against a real index', :elasticsearch do
    subject(:dumper) { adapter.create_schema_dumper({}) }

    let(:adapter) { ElasticsearchSpec.connection }

    let(:index_name) { TestIndex.name }

    # the dumped +create_table+ block of the test index
    let(:output) do
      stream = StringIO.new
      dumper.send(:table, index_name, stream)
      stream.rewind
      stream.read
    end

    before do
      TestIndex.create!(index_name) do |t|
        t.mapping :name, :text do |m|
          m.fields = { keyword: { type: 'keyword' } }
        end
        t.mapping :count, :integer
        t.mapping :title, :text, index: false, store: true

        t.setting 'index.number_of_shards', 1
        t.setting 'index.number_of_replicas', 0

        t.add_alias 'my-alias', routing: '1'
        t.meta :kind, 'demo'
      end
    end

    after { TestIndex.drop! }

    describe '#table' do
      it 'opens a forced create_table block' do
        expect(output).to start_with(%(  create_table "#{index_name}", force: true do |t|))
      end

      it 'closes the block' do
        expect(output).to end_with("  end\n")
      end

      it 'dumps the metas' do
        expect(output).to include(%(    t.meta :kind, "demo"))
      end

      it 'dumps a plain mapping' do
        expect(output).to include(%(    t.mapping :count, :integer))
      end

      it 'dumps the attributes of a mapping' do
        expect(output).to include(%(    t.mapping :name, :text, fields: { keyword: { type: "keyword" } }))
      end

      # the settings are resolved FLAT - one line per dotted path
      it 'dumps the settings' do
        expect(output).to include(%(    t.setting "index.number_of_shards", "1"))
        expect(output).to include(%(    t.setting "index.number_of_replicas", "0"))
      end

      # the internal settings are dropped by +TableSettingDefinition::IGNORE_NAMES+
      it 'skips the internal settings' do
        expect(output).not_to include('index.uuid')
        expect(output).not_to include('index.creation_date')
        expect(output).not_to include('index.provided_name')
      end

      it 'dumps the nodes in a stable order' do
        expect(output.index('t.meta')).to be < output.index('t.mapping')
        expect(output.index('t.mapping')).to be < output.index('t.setting')
      end

      # CAVEAT: the index alias is dumped as a MAPPING of the elasticsearch 'alias' FIELD type -
      # there is no +t.alias+ line. +CreateTableDefinition#transform_aliases!+ calls +self.alias+,
      # which is the column-method of the 'alias' mapping type, not +#add_alias+.
      # The dumped schema is therefore not loadable for an aliased index.
      # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::CreateTableDefinition#transform_aliases!
      it 'does not dump the index alias as an alias' do
        expect(output).not_to include('t.alias')
      end

      it 'dumps the index alias as a mapping instead' do
        expect(output).to include(%(    t.mapping :"my-alias", :alias))
      end

      context 'with nested_blocks' do
        let(:output) do
          stream = StringIO.new
          dumper.send(:table, index_name, stream, nested_blocks: true)
          stream.rewind
          stream.read
        end

        # more than one attribute is written as a block instead of a keyword list
        it 'writes a mapping with multiple attributes as a block' do
          expect(output).to include([
            %(    t.mapping :title, :text do |m|),
            %(      m.index = false),
            %(      m.store = true),
            %(    end)
          ].join("\n"))
        end

        # a single attribute stays inline
        it 'keeps a mapping with one attribute inline' do
          expect(output).to include(%(    t.mapping :name, :text, fields: { keyword: { type: "keyword" } }))
        end

        # PLEASE NOTE: a setting value is only ever a Hash when the schema was resolved NON-flat.
        # +#table_schema+ always requests +flat_settings+, so this branch is not reachable through
        # the regular path - the schema is stubbed to exercise the dumpers own formatting.
        it 'writes a multi-value setting as a block' do
          allow(adapter).to receive(:table_schema).and_return({
                                                                settings: { 'index.blocks' => { 'read' => 'true', 'write' => 'true' } },
                                                                mappings: { 'properties' => { 'a' => { 'type' => 'keyword' } } },
                                                                aliases:  {}
                                                              })

          expect(output).to include([
            %(    t.setting "index.blocks" do |s|),
            %(      s.read = "true"),
            %(      s.write = "true"),
            %(    end)
          ].join("\n"))
        end

        it 'keeps a mapping without attributes inline' do
          expect(output).to include(%(    t.mapping :count, :integer))
        end
      end

      # the whole dump of a single table is wrapped - one broken index must not kill the file
      describe 'a failing table' do
        let(:output) do
          stream = StringIO.new
          dumper.send(:table, 'nope-does-not-exist', stream)
          stream.rewind
          stream.read
        end

        it 'writes the failure as a comment' do
          expect(output).to start_with('# Could not dump table "nope-does-not-exist" because of following ActiveRecord::StatementInvalid')
        end

        it 'includes the error message' do
          expect(output).to include('index_not_found_exception')
        end

        it 'does not raise' do
          expect { output }.not_to raise_error
        end
      end

      context 'with environment related table names' do
        let(:adapter) do
          ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
            ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_suffix: '_test'))
        end

        # every table statement decorates its name by DEFAULT, so dumping the BASE name is enough
        # to keep the dump loadable in another environment (with its own prefix / suffix).
        # The former +_env_table_name(...)+ wrapping is gone.
        it 'dumps the base name' do
          expect(output).to start_with(%(  create_table "elasticsearch_record", force: true do |t|))
        end

        it 'does not wrap the name into _env_table_name anymore' do
          expect(output).not_to include('_env_table_name')
        end

        it 'does not switch the decoration off' do
          expect(output).not_to include('decorate: false')
        end

        # a globally disabled decoration would leave the base name untouched while loading, so the
        # dump has to carry the full name - written EXPLICITLY, so it also survives the switch
        # being flipped back on before the dump is loaded
        context 'with a globally disabled decoration' do
          around do |example|
            ElasticsearchRecord.decorate_table_names = false
            example.run
          ensure
            ElasticsearchRecord.decorate_table_names = true
          end

          it 'dumps the full name with decorate: false' do
            expect(output).to start_with(%(  create_table "elasticsearch_record_test", decorate: false, force: true do |t|))
          end
        end
      end

      # If the base name does not resolve BACK to the real index, the decoration has to be switched
      # off - otherwise loading the dump would address a different index.
      context 'with a base name that collides with the suffix' do
        let(:adapter) do
          ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
            ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_suffix: '_test'))
        end

        # 'elasticsearch_record_test_test' strips to 'elasticsearch_record_test', which already ends
        # with the suffix - so +_env_table_name+ would NOT append it a second time
        # (the surrounding +before+ creates this index, the +after+ below drops it again)
        let(:index_name) { "#{TestIndex.name}_test" }

        after { TestIndex.drop!(index_name) }

        it 'dumps the full name with decorate: false' do
          expect(output).to start_with(%(  create_table "elasticsearch_record_test_test", decorate: false, force: true do |t|))
        end
      end

      # the dumper may be built with an explicit prefix / suffix that differs from the connection -
      # decorating the stripped name would then resolve a completely different index
      context 'with dumper options that differ from the connection' do
        let(:dumper) { adapter.create_schema_dumper({ table_name_suffix: '_record_test' }) }

        it 'dumps the full name with decorate: false' do
          expect(output).to start_with(%(  create_table "elasticsearch_record_test", decorate: false, force: true do |t|))
        end
      end
    end

    describe '#dump' do
      # PLEASE NOTE: the tables are stubbed - a real dump would walk EVERY index of the (shared)
      # cluster, which is neither fast nor the subject here
      before { allow(adapter).to receive(:tables).and_return([index_name]) }

      let(:output) do
        stream = StringIO.new
        dumper.dump(stream)
        stream.rewind
        stream.read
      end

      it 'writes the schema definition header' do
        expect(output).to include('ActiveRecord::Schema[')
        expect(output).to include('define(version: 0) do')
      end

      it 'includes the dumped table' do
        expect(output).to include(%(create_table "#{index_name}", force: true do |t|))
      end

      it 'skips an ignored table' do
        allow(adapter).to receive(:tables).and_return([index_name, 'schema_migrations'])

        expect(output).not_to include('create_table "schema_migrations"')
      end
    end
  end
end
