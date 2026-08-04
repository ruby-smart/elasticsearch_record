# frozen_string_literal: true

# Covers every method of +ElasticsearchRecord::Relation::CoreMethods+.
#
# The module carries the relation methods that have no SQL counterpart (+resolve+, +to_query+,
# +msearch+) plus the two ActiveRecord overrides that guard against sorting on the +_id+ field -
# which most clusters disallow by default.
#
# see @ ElasticsearchRecord::Relation::CoreMethods
RSpec.describe ElasticsearchRecord::Relation::CoreMethods, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  before do
    TestIndex.create!

    model.create!(name: 'alpha', count: 1, active: true)
    model.create!(name: 'beta', count: 2, active: false)
    model.create!(name: 'gamma', count: 3, active: true)
    model.api.refresh!
  end

  after do
    TestIndex.drop!
    TestIndex.drop!(pk_index_name)
  end

  subject(:relation) { model.all }

  let(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'CoreMethodsSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # a second index whose primary_key is a REAL mapping - so the '_id' restriction does not apply
  let(:pk_index_name) { "#{TestIndex.name}_pk" }

  let(:pk_model) do
    TestIndex.create!(pk_index_name) do |t|
      t.mapping :uuid, :keyword
      t.mapping :name, :keyword
      t.meta :primary_key, 'uuid'
    end

    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'CoreMethodsPkSpecModel'
    }.tap { |klass|
      klass.table_name = pk_index_name
      klass.reset_column_information
    }
  end

  #######################
  # INSTANTIATE RECORDS #
  #######################

  describe '#instantiate_records' do
    # the +total+ of the RESPONSE is slurped while the records are built - it is the number of
    # MATCHING documents, which is not the number of returned records
    it 'slurps the total out of the result' do
      relation.load

      expect(relation.total).to eq(3)
    end

    it 'keeps the full total for a limited relation' do
      limited = relation.limit(2)
      limited.load

      expect(limited.to_a.size).to eq(2)
      expect(limited.total).to eq(3)
    end

    it 'resolves the total of a scoped relation' do
      scoped = model.where(active: true)
      scoped.load

      expect(scoped.total).to eq(2)
    end

    # defensive fallback: everything this gem builds hands over an +ElasticsearchRecord::Result+,
    # but a plain Array must not blow up the total
    it 'falls back to the row count for a non-Result' do
      relation.send(:instantiate_records, [])

      expect(relation.instance_variable_get(:@total)).to eq(0)
    end
  end

  ###########
  # RESOLVE #
  ###########

  describe '#resolve' do
    it 'returns the raw result' do
      expect(relation.resolve).to be_a(ElasticsearchRecord::Result)
    end

    it 'resolves the response without instantiating records' do
      result = relation.resolve

      expect(result.total).to eq(3)
      expect(result.length).to eq(3)
    end

    it 'respects the current scope' do
      expect(model.where(active: true).resolve.total).to eq(2)
    end

    # +resolve+ builds the arel, which memoizes it - the relation can no longer be changed
    it 'makes the relation immutable' do
      relation.resolve

      expect { relation.where!(name: 'alpha') }.to raise_error(ActiveRecord::ImmutableRelation)
    end

    it 'instruments with a custom name' do
      allow(model.connection).to receive(:select_all).and_call_original

      relation.resolve('Custom')

      expect(model.connection).to have_received(:select_all).with(anything, "#{model.name} Custom")
    end

    it 'instruments with "Load" by default' do
      allow(model.connection).to receive(:select_all).and_call_original

      relation.resolve

      expect(model.connection).to have_received(:select_all).with(anything, "#{model.name} Load")
    end
  end

  ############
  # TO QUERY #
  ############

  describe '#to_query' do
    # the query arguments are what the adapter finally hands to the elasticsearch-api client
    it 'returns the API arguments of the current relation' do
      expect(relation.to_query).to eq({ index: TestIndex.name })
    end

    it 'includes the built body' do
      expect(model.where(active: true).to_query)
        .to eq({ index: TestIndex.name,
                 body:  { query: { bool: { filter: [{ term: { 'active' => true } }] } } } })
    end

    it 'returns the failed body for a NullRelation' do
      expect(relation.none.to_query[:body])
        .to eq(ElasticsearchRecord::Query::FAILED_BODIES[ElasticsearchRecord::Query::TYPE_SEARCH])
    end
  end

  ###########
  # MSEARCH #
  ###########

  describe '#msearch' do
    # without items the CURRENT relation is executed - a single search in a msearch request
    it 'executes the current relation without provided items' do
      responses = relation.msearch

      expect(responses.map(&:class)).to eq([ElasticsearchRecord::Result])
      expect(responses.first.total).to eq(3)
    end

    it 'yields a spawn per provided item' do
      yielded = []

      relation.msearch([1, 2]) { |query, value| yielded << [query, value]; query.where(count: value) }

      expect(yielded.map(&:last)).to eq([1, 2])
      expect(yielded.map(&:first)).to all(be_a(ActiveRecord::Relation))
      # every yield receives its OWN spawn - never the receiver
      expect(yielded.map(&:first)).to all(satisfy { |spawn| !spawn.equal?(relation) })
    end

    it 'returns one result per provided item' do
      responses = relation.msearch([1, 2]) { |query, value| query.where(count: value) }

      expect(responses.map(&:total)).to eq([1, 1])
    end

    it 'keeps the order of the provided items' do
      responses = relation.msearch([3, 1]) { |query, value| query.where(count: value) }

      expect(responses.map { |result| result.results.first['count'] }).to eq([3, 1])
    end

    # the resolve option chops a single node out of every result
    it 'resolves the provided node from each result' do
      expect(relation.msearch([1, 2], resolve: :total) { |query, value| query.where(count: value) })
        .to eq([1, 1])
    end

    it 'accepts a String resolve option' do
      expect(relation.msearch([1], resolve: 'total') { |query, value| query.where(count: value) })
        .to eq([1])
    end

    # transpose zips the provided items with their responses
    it 'transposes the items with their responses' do
      expect(relation.msearch([1, 2], resolve: :total, transpose: true) { |query, value| query.where(count: value) })
        .to eq({ 1 => 1, 2 => 1 })
    end

    it 'transposes the raw results as well' do
      responses = relation.msearch([1], transpose: true) { |query, value| query.where(count: value) }

      expect(responses.keys).to eq([1])
      expect(responses[1]).to be_a(ElasticsearchRecord::Result)
    end

    describe 'on a NullRelation' do
      # WARNING documented on the method: a NullRelation returns nil right away
      it 'returns nil without yielding' do
        yielded = false

        expect(relation.none.msearch([1]) { |query, _value| yielded = true; query }).to be_nil
        expect(yielded).to be(false)
      end

      it 'still executes with the keep_null_relation flag' do
        responses = relation.none.msearch([1], keep_null_relation: true) { |query, _value| query }

        expect(responses.map(&:total)).to eq([0])
      end
    end
  end

  ####################
  # ORDERED RELATION #
  ####################

  # +ordered_relation+ is what +#first+ / +#last+ / batching rely on to get a stable order
  describe '#ordered_relation' do
    it 'keeps an already ordered relation' do
      ordered = model.order(:name)

      expect(ordered.ordered_relation).to equal(ordered)
    end

    # sorting on the '_id' field requires the (by default disabled) cluster setting
    context "with the '_id' primary_key" do
      it 'does not order when the fielddata access is disallowed' do
        allow(model.connection).to receive(:access_id_fielddata?).and_return(false)

        expect(relation.ordered_relation.order_values).to be_empty
      end

      it 'orders by the _id when the fielddata access is allowed' do
        allow(model.connection).to receive(:access_id_fielddata?).and_return(true)

        expect(relation.ordered_relation.order_values.size).to eq(1)
      end

      # the implicit_order_column is usable even without the _id access
      it 'orders by the implicit_order_column alone' do
        allow(model.connection).to receive(:access_id_fielddata?).and_return(false)
        model.implicit_order_column = 'name'

        expect(relation.ordered_relation.order_values.size).to eq(1)
      end
    end

    context 'with a mapped primary_key' do
      it 'orders by the primary_key' do
        expect(pk_model.primary_key).to eq('uuid')
        expect(pk_model.all.ordered_relation.order_values.size).to eq(1)
      end

      it 'orders by the implicit_order_column AND the primary_key' do
        pk_model.implicit_order_column = 'name'

        expect(pk_model.all.ordered_relation.order_values.size).to eq(2)
      end

      # no need to order twice by the same column
      it 'orders once when both are the same column' do
        pk_model.implicit_order_column = 'uuid'

        expect(pk_model.all.ordered_relation.order_values.size).to eq(1)
      end
    end
  end

  ######################
  # REVERSE SQL ORDER  #
  ######################

  describe '#reverse_sql_order' do
    it 'delegates an existing order to ActiveRecord' do
      expect(model.order(:name).send(:reverse_sql_order, model.order(:name).order_values)).to be_present
    end

    context 'without any order' do
      it 'reverses by the primary_key when it is a real mapping' do
        expect(pk_model.all.send(:reverse_sql_order, []).size).to eq(1)
      end

      it "reverses by the '_id' when the fielddata access is allowed" do
        allow(model.connection).to receive(:access_id_fielddata?).and_return(true)

        expect(relation.send(:reverse_sql_order, []).size).to eq(1)
      end

      # this is the case most clusters are in - there is simply no reversible order
      it 'raises when the _id fielddata access is disallowed' do
        allow(model.connection).to receive(:access_id_fielddata?).and_return(false)

        expect { relation.send(:reverse_sql_order, []) }
          .to raise_error(ActiveRecord::IrreversibleOrderError, /indices.id_field_data.enabled/)
      end
    end

    # +#last+ resolves through the reversed order - so it inherits the restriction
    describe 'through #last' do
      it 'raises on an unordered relation with a restricted _id' do
        allow(model.connection).to receive(:access_id_fielddata?).and_return(false)

        expect { relation.last }.to raise_error(ActiveRecord::IrreversibleOrderError)
      end

      it 'resolves for an explicitly ordered relation' do
        expect(model.order(:name).last.name).to eq('gamma')
      end

      it 'resolves for a mapped primary_key' do
        pk_model.api.index([{ uuid: 'u1', name: 'a' }, { uuid: 'u2', name: 'b' }])

        expect(pk_model.all.last.uuid).to eq('u2')
      end
    end
  end
end
