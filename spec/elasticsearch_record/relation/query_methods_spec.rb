# frozen_string_literal: true

# Verifies that metadata fields ('_id', '_score', ...) cannot be provided as a projection.
#
# Metadata fields are NOT part of the +_source+ node - providing them to +select+ would
# silently build a +_source+-filter that never matches. The only exception is '_id': as the
# +primary_key+ it stays resolvable through +pluck+ / +ids+.
#
# see @ ElasticsearchRecord::Relation::QueryMethods#select / #pluck
# see @ ElasticsearchRecord::Result#cast_values
RSpec.describe 'ElasticsearchRecord::Relation::QueryMethods projections', :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  before do
    TestIndex.create!

    model.create!(name: 'alpha', count: 1, active: true)
    model.create!(name: 'beta', count: 2, active: false)
    model.api.refresh!
  end

  after { TestIndex.drop! }

  subject(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'QueryMethodsSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # every metadata field except '_id'
  let(:metadata_fields) { %w[_index _score _ignored] }

  describe '#select' do
    it 'raises for every metadata field' do
      (metadata_fields + ['_id']).each do |field|
        expect { model.select(field.to_sym) }.to raise_error(
          ActiveRecord::UnknownAttributeReference, /Unable to select metadata attributes.*#{field}/m
        )
      end
    end

    it 'raises for a metadata field provided as String' do
      expect { model.select('_id') }.to raise_error(
        ActiveRecord::UnknownAttributeReference, /"_id"/
      )
    end

    it 'raises and only reports the invalid field when mixed with a valid one' do
      expect { model.select(:name, :_id) }.to raise_error(
        ActiveRecord::UnknownAttributeReference
      ) { |error|
        expect(error.message).to include('"_id"')
        expect(error.message).not_to include('"name"')
        # the message points to the alternative
        expect(error.message).to include('QueryMethodsSpecModel.first._id')
      }
    end

    it 'does not raise for regular source columns' do
      expect { model.select(:name) }.not_to raise_error
      expect { model.select(:name, :count) }.not_to raise_error

      expect(model.select(:name).select_values).to eq([:name])
    end

    it 'does not raise when called with a block' do
      # +select+ with a block is Enumerable#select and must not be touched by the guard
      expect { model.select { |record| record.name == 'alpha' } }.not_to raise_error
      expect(model.select { |record| record.name == 'alpha' }.size).to eq(1)
    end

    it 'ignores fields that are not a Symbol or String' do
      # Arel-nodes are not resolvable as a metadata field and must not be checked
      expect { model.select(model.arel_table[:name]) }.not_to raise_error
      expect(model.select(model.arel_table[:name]).to_sql.body).to eq({ _source: ['name'] })
    end

    it 'builds a _source filter for regular columns' do
      query = model.select(:name).to_sql

      expect(query.body).to eq({ _source: ['name'] })
      expect(query.columns).to eq(['name'])
    end

    it 'does not restrict the _source without a select' do
      query = model.all.to_sql

      expect(query.body).to eq({})
      expect(query.columns).to match_array(model.source_column_names)
    end
  end

  describe '#pluck' do
    it 'resolves metadata fields that are returned on the document level' do
      # '_id', '_index' & '_score' are always returned by Elasticsearch
      expect(model.pluck(:_id)).to all(be_present)
      expect(model.pluck(:_index)).to all(eq(TestIndex.name))
      expect(model.pluck(:_score)).to all(be_a(Float))
    end

    it 'resolves multiple metadata fields' do
      expect(model.pluck(:_id, :_score)).to all(match([be_present, be_a(Float)]))
    end

    it 'resolves metadata fields mixed with source columns' do
      expect(model.pluck(:_id, :name).map(&:last)).to match_array(%w[alpha beta])
      expect(model.pluck(:_id, :name).map(&:first)).to all(be_present)

      # the order of the provided columns must be kept
      expect(model.pluck(:name, :_id).map(&:first)).to match_array(%w[alpha beta])
    end

    it 'resolves metadata fields through #pick' do
      expect(model.all.pick(:_score)).to be_a(Float)
    end

    it "resolves the '_id' primary_key" do
      ids = model.pluck(:_id)

      expect(ids.size).to eq(2)
      expect(ids).to all(be_a(String))
      expect(ids).to all(be_present)
    end

    it "resolves the '_id' primary_key provided as String" do
      # the '_id' edge-case must not depend on the provided class (Symbol / String)
      expect(model.pluck('_id')).to match_array(model.pluck(:_id))
    end

    it 'does not resolve metadata fields that are not returned by Elasticsearch' do
      # '_type' & '_ignored' are not part of the document level (unless they apply)
      expect(model.pluck(:_type)).to all(be_nil)
      expect(model.pluck(:_ignored)).to all(be_nil)
    end

    it 'resolves regular source columns' do
      expect(model.pluck(:name)).to match_array(%w[alpha beta])
      expect(model.pluck(:name, :count)).to match_array([['alpha', 1], ['beta', 2]])
    end

    it "resolves the '_id' through #pick" do
      expect(model.all.pick(:_id)).to be_present
    end

    it 'ignores fields that are not a Symbol or String' do
      # Arel-nodes are not resolvable as a metadata field and must not be checked
      expect { model.pluck(model.arel_table[:name]) }.not_to raise_error
      expect(model.pluck(model.arel_table[:name])).to match_array(%w[alpha beta])
    end
  end

  # +ids+ bypasses +pluck+ (it assigns +select_values+ directly) but resolves through
  # +ElasticsearchRecord::Result#cast_values+ - so it depends on the '_id' exception.
  describe '#ids' do
    it 'resolves real values on an unloaded relation' do
      ids = model.all.ids

      expect(ids.size).to eq(2)
      expect(ids).to all(be_present)
    end

    it 'resolves real values on a filtered relation' do
      ids = model.where(active: true).ids

      expect(ids.size).to eq(1)
      expect(ids.first).to be_present
    end

    it 'resolves the same values on a loaded relation' do
      relation = model.all
      unloaded = relation.ids
      relation.load

      expect(relation.ids).to match_array(unloaded)
    end
  end

  # metadata fields must never end up within the +_source+-filter - they are resolved from the
  # document level. If ONLY metadata fields are projected, no +_source+ is transferred at all.
  # see @ Arel::Visitors::ElasticsearchQuery#visit_Selects
  describe 'the built query' do
    # builds the query the way +pluck+ does (it assigns +select_values+ directly)
    def query_for(*columns)
      relation               = model.all.spawn
      relation.select_values = relation.send(:arel_columns, columns)
      relation.to_sql
    end

    it 'disables the _source for a single metadata field' do
      expect(query_for(:_id).body).to eq({ _source: false })
      expect(query_for(:_score).body).to eq({ _source: false })
    end

    it 'disables the _source for multiple metadata fields' do
      expect(query_for(:_id, :_score).body).to eq({ _source: false })
    end

    it 'removes metadata fields but keeps the source columns' do
      expect(query_for(:_id, :name).body).to eq({ _source: ['name'] })
    end

    it 'keeps a regular _source filter untouched' do
      expect(query_for(:name).body).to eq({ _source: ['name'] })
      expect(query_for(:name, :count).body).to eq({ _source: %w[name count] })
    end

    it 'forwards all provided columns to the result' do
      # the metadata fields must stay within the columns - they are resolved from the document
      expect(query_for(:_id, :name).columns).to eq(%w[_id name])
      expect(query_for(:_id).columns).to eq(['_id'])
    end

    # the +COLUMNS_NONE+ marker is the only way to clear the columns claimed by
    # +visit_Arel_Nodes_SelectCore+ - a +configure+ can only reach the query-body.
    # see @ ElasticsearchRecord::Query::COLUMNS_NONE
    context "with the '#{ElasticsearchRecord::Query::COLUMNS_NONE}' (COLUMNS_NONE) marker" do
      it 'disables the _source and clears the columns' do
        query = query_for(ElasticsearchRecord::Query::COLUMNS_NONE)

        expect(query.body).to eq({ _source: false })
        # the cleared columns are the whole point - without them +Result+ would try to
        # resolve the (never transferred) source fields
        expect(query.columns).to eq([])
      end

      it 'builds the same query through #meta_only!' do
        query = model.all.meta_only!.to_sql

        expect(query.body).to include({ _source: false })
        expect(query.body).not_to have_key(:aggs)
        expect(query.columns).to eq([])
      end

      # PLEASE NOTE: +visit_Selects+ only inspects the FIRST projection, so the marker wins and
      # any additional field is silently discarded. Pinned here as a known sharp edge.
      it 'discards any additional field' do
        expect(query_for(ElasticsearchRecord::Query::COLUMNS_NONE, :name).body).to eq({ _source: false })
      end

      it 'does not capture ordinary projections' do
        expect(query_for(:name).body).to eq({ _source: ['name'] })
        expect(query_for(:name).columns).to eq(['name'])
      end
    end
  end

  describe ElasticsearchRecord::Result do
    # +cast_values+ resolves the types itself whenever +type_overrides+ is not an Array.
    # ActiveRecord's +pluck+ always provides an Array, so this path is only reachable
    # through a direct call - it must not raise.
    it 'casts multiple columns without provided type overrides' do
      result = model.connection.select_all(model.all.arel, 'QueryMethodsSpec Load')

      expect(result.columns.size).to be > 1
      expect { result.cast_values({}) }.not_to raise_error
      expect(result.cast_values({}).size).to eq(2)
    end

    it 'casts a single column without provided type overrides' do
      result = model.connection.select_all(model.select(:name).arel, 'QueryMethodsSpec Load')

      expect { result.cast_values({}) }.not_to raise_error
      expect(result.cast_values({})).to match_array(%w[alpha beta])
    end
  end

  describe 'unaffected behaviour' do
    it 'still resolves aggregations' do
      expect(model.count).to eq(2)
      expect(model.sum(:count)).to eq(3)
      expect(model.maximum(:count)).to eq(2)
      expect(model.group(:active).count).to eq({ false => 1, true => 1 })
    end

    it 'still supports metadata within #where' do
      record = model.first

      expect(model.where(_id: record._id).first.name).to eq(record.name)
    end

    it 'still exposes metadata on instantiated records' do
      record = model.first

      expect(record._id).to be_a(String).and be_present
      expect(record._score).to be_a(Float)
      expect(record.attributes.keys).to include('_id', '_index', '_score')
    end

    it 'still resolves a record through its primary_key' do
      record = model.first

      expect(model.find(record._id).name).to eq(record.name)
    end
  end
end
