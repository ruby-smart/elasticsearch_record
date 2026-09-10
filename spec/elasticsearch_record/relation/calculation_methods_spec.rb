# frozen_string_literal: true

# Covers every method of +ElasticsearchRecord::Relation::CalculationMethods+.
#
# Elasticsearch has no SQL aggregate functions - every calculation here is an ES *aggregation*
# that is spawned onto the relation, executed, and then reduced to the metric node of the response.
# +#count+ is the odd one out: it branches into six different strategies depending on what the
# relation carries (distinct, column, group, select, limit).
#
# PLEASE NOTE: every calculation runs against a real index - the values below are computed by
# Elasticsearch, not by this gem, so stubbing them would test nothing.
#
# see @ ElasticsearchRecord::Relation::CalculationMethods
RSpec.describe ElasticsearchRecord::Relation::CalculationMethods, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  #
  # The fixture is deliberately small & fully deterministic:
  #   name    count  score  active
  #   alpha       1    2.0    true
  #   beta        2    4.0   false
  #   gamma       3    6.0    true
  #   delta     nil    nil    true    <- the missing values are what +count(column)+ filters on
  before do
    TestIndex.create!(TestIndex.name) do |t|
      t.mapping :name, :keyword
      t.mapping :count, :integer
      t.mapping :score, :float
      t.mapping :active, :boolean

      t.setting 'index.number_of_shards', '1'
      t.setting 'index.number_of_replicas', '0'
    end

    model.create!(name: 'alpha', count: 1, score: 2.0, active: true)
    model.create!(name: 'beta', count: 2, score: 4.0, active: false)
    model.create!(name: 'gamma', count: 3, score: 6.0, active: true)
    model.create!(name: 'delta', active: true)
    model.api.refresh!
  end

  after { TestIndex.drop! }

  subject(:relation) { model.all }

  let(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'CalculationMethodsSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  #########
  # COUNT #
  #########

  describe '#count' do
    it 'counts every document' do
      expect(relation.count).to eq(4)
    end

    it 'respects the current scope' do
      expect(model.where(active: true).count).to eq(3)
    end

    # +:all+ is the ActiveRecord idiom for "no column" - it must not become a column filter
    it 'treats :all like no column at all' do
      expect(relation.count(:all)).to eq(relation.count)
    end

    # a provided column counts only the documents where the field EXISTS - Elasticsearch does not
    # store nil values, so a missing field is the equivalent of SQL NULL
    describe 'with a provided column' do
      it 'counts only documents where the field exists' do
        expect(relation.count(:count)).to eq(3)
      end

      it 'counts every document for an always present field' do
        expect(relation.count(:name)).to eq(4)
      end

      it 'combines with the current scope' do
        expect(model.where(active: true).count(:count)).to eq(2)
      end
    end

    # distinct + column resolves through the cardinality aggregation
    describe 'with a distinct value' do
      it 'resolves the cardinality of the provided column' do
        expect(relation.distinct.count(:active)).to eq(2)
        expect(relation.distinct.count(:name)).to eq(4)
      end

      # without a column there is nothing to be distinct about - it falls through to the total
      it 'ignores the distinct without a provided column' do
        expect(relation.distinct.count).to eq(4)
      end
    end

    # a grouped count returns the buckets - not a number
    describe 'with a group value' do
      it 'returns the composite buckets' do
        expect(model.group(:active).count).to eq({ false => 1, true => 3 })
      end

      it 'returns a nested key for multiple groups' do
        expect(model.group(:active, :count).count)
          .to eq({ { 'active' => false, 'count' => 2 } => 1,
                   { 'active' => true, 'count' => 1 } => 1,
                   { 'active' => true, 'count' => 3 } => 1 })
      end
    end

    # a projection is treated like a group - the same composite path
    describe 'with a select value' do
      it 'returns the composite buckets' do
        expect(model.select(:active).count).to eq({ false => 1, true => 3 })
      end
    end

    # Elasticsearch always answers a count with the FULL total, so the SQL 'LIMIT n OFFSET m'
    # semantic is applied on the resolved total.
    # see @ ElasticsearchRecord::Relation::CalculationMethods#_resolve_limited_count
    describe 'with a limit' do
      # a zero limit short-circuits - no query is executed at all
      it 'returns 0 for a zero limit' do
        expect(relation.limit(0).count).to eq(0)
      end

      it 'caps the count at the provided limit' do
        expect(relation.limit(2).count).to eq(2)
        expect(model.where(active: true).limit(1).count).to eq(1)
      end

      it 'returns the total for a limit above it' do
        expect(relation.limit(99).count).to eq(4)
      end

      # this is what +#count+ is expected to agree with
      it 'agrees with the number of loaded records' do
        expect(relation.limit(2).count).to eq(relation.limit(2).to_a.size)
        expect(relation.limit(99).count).to eq(relation.limit(99).to_a.size)
      end

      # +#size+ resolves through +#count+ on an unloaded relation
      it 'is what #size resolves on an unloaded relation' do
        expect(relation.limit(2).size).to eq(2)
      end

      it 'also caps a column count' do
        expect(relation.limit(1).count(:count)).to eq(1)
      end

      # the argument is still built - it is a (best-effort) early termination hint for the cluster
      it 'builds the terminate_after argument from the limit' do
        captured = nil
        allow(model.connection).to receive(:select_count).and_wrap_original do |original, arel, *args|
          captured = model.connection.to_sql(model.connection.send(:arel_from_relation, arel))
          original.call(arel, *args)
        end

        relation.limit(2).count

        expect(captured.arguments).to eq({ terminate_after: 2 })
      end
    end

    describe 'with an offset' do
      it 'subtracts the offset from the count' do
        expect(relation.offset(1).count).to eq(3)
      end

      it 'never returns a negative count' do
        expect(relation.offset(99).count).to eq(0)
      end

      it 'combines with a limit' do
        expect(relation.offset(1).limit(2).count).to eq(2)
        expect(relation.offset(3).limit(2).count).to eq(1)
      end

      it 'agrees with the number of loaded records' do
        expect(relation.offset(1).limit(2).count).to eq(relation.offset(1).limit(2).to_a.size)
        expect(relation.offset(3).count).to eq(relation.offset(3).to_a.size)
      end
    end

    # +count+ with a block is Enumerable#count - it must load the records and count in ruby
    describe 'with a block' do
      it 'falls back to the ActiveRecord implementation' do
        expect(relation.count { |record| record.active }).to eq(3)
      end
    end

    describe 'on a NullRelation' do
      # a failed query is never executed - the count is known upfront
      it 'returns 0 without executing a query' do
        expect(relation.none.count).to eq(0)
      end
    end
  end

  #######################
  # CALCULATE AGGREGATION #
  #######################

  describe '#calculate_aggregation' do
    # a single column becomes the 'field' node
    it 'builds a single-field aggregation' do
      expect(relation.calculate_aggregation(:sum, :count)).to eq({ 'value' => 6.0 })
    end

    # multiple columns become the 'fields' node
    it 'builds a multi-field aggregation' do
      result = relation.calculate_aggregation(:matrix_stats, :count, :score)

      expect(result['fields'].map { |field| field['name'] }).to match_array(%w[count score])
    end

    # without a node the WHOLE metric response is returned
    it 'returns the whole metric node without a provided node' do
      expect(relation.calculate_aggregation(:stats, :count))
        .to eq({ 'count' => 3, 'min' => 1.0, 'max' => 3.0, 'avg' => 2.0, 'sum' => 6.0 })
    end

    it 'chops the provided node out of the response' do
      expect(relation.calculate_aggregation(:sum, :count, node: :value)).to eq(6.0)
    end

    # the opts are merged into the metric definition
    it 'merges the provided opts into the metric' do
      expect(relation.calculate_aggregation(:percentiles, :count, opts: { percents: [50] }, node: :values))
        .to eq({ '50.0' => 2.0 })
    end

    it 'respects the current scope' do
      expect(relation.where(active: true).calculate_aggregation(:sum, :count, node: :value)).to eq(4.0)
    end

    # the aggregation is spawned - the receiver keeps its own (empty) aggs
    it 'does not mutate the receiver' do
      relation.calculate_aggregation(:sum, :count)

      expect(relation.aggs_clause).to be_empty
      expect(relation).not_to be_loaded
    end

    it 'is aliased as #calculate' do
      expect(relation.calculate(:sum, :count, node: :value)).to eq(6.0)
    end

    it 'returns nil on a NullRelation' do
      expect(relation.none.calculate_aggregation(:sum, :count)).to be_nil
    end
  end

  ####################
  # METRIC SHORTCUTS #
  ####################

  # these all resolve the +value+ node - a single number
  describe 'the single-value metrics' do
    it '#sum sums the column' do
      expect(relation.sum(:count)).to eq(6.0)
    end

    it '#average averages the column' do
      expect(relation.average(:count)).to eq(2.0)
    end

    it '#minimum resolves the smallest value' do
      expect(relation.minimum(:count)).to eq(1.0)
    end

    it '#maximum resolves the largest value' do
      expect(relation.maximum(:count)).to eq(3.0)
    end

    # counts the DISTINCT values - the documents without the field are not counted
    it '#cardinality counts the distinct values' do
      expect(relation.cardinality(:name)).to eq(4)
      expect(relation.cardinality(:active)).to eq(2)
      expect(relation.cardinality(:count)).to eq(3)
    end

    it 'respects the current scope' do
      expect(model.where(active: true).sum(:count)).to eq(4.0)
      expect(model.where(active: true).maximum(:count)).to eq(3.0)
    end

    # a document without the field is simply not part of the aggregation
    it 'ignores documents without the field' do
      expect(relation.average(:count)).to eq(2.0)
    end
  end

  # these return the whole metric node - a Hash
  describe 'the multi-value metrics' do
    it '#stats returns count, min, max, avg & sum' do
      expect(relation.stats(:count))
        .to eq({ 'count' => 3, 'min' => 1.0, 'max' => 3.0, 'avg' => 2.0, 'sum' => 6.0 })
    end

    # the extended version adds the spread metrics on top of the +stats+ node - it is the ONLY
    # aggregation that provides a standard deviation (Elasticsearch has no 'std_dev' metric)
    describe '#extended_stats' do
      it 'returns the stats plus the spread metrics' do
        result = relation.extended_stats(:count)

        expect(result).to include('count' => 3, 'min' => 1.0, 'max' => 3.0, 'avg' => 2.0, 'sum' => 6.0)
        expect(result['sum_of_squares']).to eq(14.0)
        expect(result['variance']).to be_within(0.0001).of(0.6666)
        expect(result['std_deviation']).to be_within(0.0001).of(0.8164)
      end

      # the bounds default to TWO standard deviations around the mean
      it 'returns the default std_deviation_bounds' do
        bounds = relation.extended_stats(:count)['std_deviation_bounds']

        expect(bounds['upper']).to be_within(0.0001).of(3.6329)
        expect(bounds['lower']).to be_within(0.0001).of(0.3670)
      end

      it 'applies a custom sigma to the bounds' do
        bounds = relation.extended_stats(:count, sigma: 1)['std_deviation_bounds']

        expect(bounds['upper']).to be_within(0.0001).of(2.8164)
        expect(bounds['lower']).to be_within(0.0001).of(1.1835)
      end

      it 'ignores documents without the field' do
        expect(relation.extended_stats(:count)['count']).to eq(3)
      end
    end

    it '#string_stats returns the string statistics' do
      stats = relation.string_stats(:name)

      expect(stats['count']).to eq(4)
      expect(stats['min_length']).to eq(4)
      expect(stats['max_length']).to eq(5)
      expect(stats['avg_length']).to eq(4.75)
      expect(stats['entropy']).to be_a(Float)
    end

    it '#boxplot returns the box plot values' do
      expect(relation.boxplot(:count))
        .to eq({ 'min' => 1.0, 'max' => 3.0, 'q1' => 1.5, 'q2' => 2.0, 'q3' => 2.5,
                 'lower' => 1.0, 'upper' => 3.0 })
    end

    # PLEASE NOTE: this one resolves the +values+ node - not the whole metric
    it '#percentiles returns the default percentiles' do
      percentiles = relation.percentiles(:count)

      expect(percentiles.keys).to eq(%w[1.0 5.0 25.0 50.0 75.0 95.0 99.0])
      expect(percentiles['50.0']).to eq(2.0)
    end

    it '#percentile_ranks returns the rank per provided value' do
      expect(relation.percentile_ranks(:count, [1, 3]).keys).to eq(%w[1.0 3.0])
      expect(relation.percentile_ranks(:count, [3])['3.0']).to be > 50
    end

    it '#median_absolute_deviation returns the deviation' do
      expect(relation.median_absolute_deviation(:count)).to eq({ 'value' => 1.0 })
    end

    describe '#matrix_stats' do
      it 'returns the statistics per provided field' do
        result = relation.matrix_stats(:count, :score)

        expect(result['doc_count']).to eq(3)
        expect(result['fields'].map { |field| field['name'] }).to match_array(%w[count score])
      end

      it 'includes the correlation between the fields' do
        field = relation.matrix_stats(:count, :score)['fields'].find { |f| f['name'] == 'count' }

        expect(field['correlation']).to eq({ 'count' => 1.0, 'score' => 1.0 })
      end

      # the metric quantifies the relationship BETWEEN fields, so a single column is meaningless -
      # and would additionally take the 'field'-branch of +#calculate_aggregation+, which
      # matrix_stats does not accept. The guard turns that cluster error into an ArgumentError.
      it 'raises for a single provided column' do
        expect { relation.matrix_stats(:count) }
          .to raise_error(ArgumentError, /less than two columns \(1 provided\) @ CalculationMethodsSpecModel!/)
      end

      it 'raises without any column' do
        expect { relation.matrix_stats }
          .to raise_error(ArgumentError, /less than two columns \(0 provided\)/)
      end

      # the guard is an argument check - it fires before the query is ever built
      it 'raises without touching the cluster' do
        allow(model.connection).to receive(:api).and_call_original

        expect { relation.matrix_stats(:count) }.to raise_error(ArgumentError)
        expect(model.connection).not_to have_received(:api)
      end

      # ... and before the NullRelation short-circuit, so a wrong call never passes silently
      it 'also raises on a NullRelation' do
        expect { relation.none.matrix_stats(:count) }.to raise_error(ArgumentError)
      end
    end
  end

  #################
  # NULL RELATION #
  #################

  # every calculation short-circuits on a failed query - the documented +nil+ return
  describe 'on a NullRelation' do
    subject(:relation) { model.all.none }

    {
      sum:                       [:count],
      average:                   [:count],
      minimum:                   [:count],
      maximum:                   [:count],
      cardinality:               [:count],
      median_absolute_deviation: [:count],
      stats:                     [:count],
      extended_stats:            [:count],
      string_stats:              [:name],
      boxplot:                   [:count],
      percentiles:               [:count]
    }.each do |method, args|
      it "##{method} returns nil" do
        expect(relation.public_send(method, *args)).to be_nil
      end
    end

    it '#percentile_ranks returns nil' do
      expect(relation.percentile_ranks(:count, [1])).to be_nil
    end

    it '#matrix_stats returns nil' do
      expect(relation.matrix_stats(:count, :score)).to be_nil
    end

    # the NullRelation guard fires before any query is built - nothing reaches the cluster
    it 'does not execute any query' do
      allow(model.connection).to receive(:api).and_call_original

      relation.sum(:count)

      expect(model.connection).not_to have_received(:api)
    end
  end
end
