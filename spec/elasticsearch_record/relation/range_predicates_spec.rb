# frozen_string_literal: true

# Covers range & comparison predicates - +where(count: 1..5)+ and friends.
#
# Before this existed, EVERY range shape raised an +UnsupportedVisitError+, since the visitor had
# no +visit_Arel_Nodes_Between+ / +GreaterThan+ / +LessThan+ / +Not+ / +NotIn+ at all. The only way
# to build a range was the raw escape hatch +filter(range: {...})+.
#
# IMPORTANT: only the modern +gt+ / +gte+ / +lt+ / +lte+ keys are ever generated. Elasticsearch
# deprecated +from+ / +to+ / +include_lower+ / +include_upper+ with 8.16 - they still resolve, but
# emit a deprecation warning and are scheduled for removal.
#
# see @ Arel::Visitors::ElasticsearchQuery#visit_Arel_Nodes_Between
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range - reads the very same keys
RSpec.describe 'ElasticsearchRecord::Relation range predicates', :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+.
  before do
    TestIndex.create!

    model.create!(name: 'alpha', count: 1, created_at: '2020-01-01')
    model.create!(name: 'beta',  count: 3, created_at: '2021-06-15')
    model.create!(name: 'gamma', count: 5, created_at: '2022-12-31')
    model.api.refresh!
  end

  after { TestIndex.drop! }

  subject(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'RangePredicatesSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # the +bool+ node of the compiled query - the part every predicate assigns into
  def bool_for(relation)
    relation.to_query[:body][:query][:bool]
  end

  describe 'generated query' do
    it 'builds an inclusive range from a closed Range' do
      expect(bool_for(model.where(count: 1..5)))
        .to eq({ filter: [{ range: { 'count' => { gte: 1, lte: 5 } } }] })
    end

    it 'builds an exclusive upper bound from an exclusive Range' do
      expect(bool_for(model.where(count: 1...5)))
        .to eq({ filter: [{ range: { 'count' => { gte: 1, lt: 5 } } }] })
    end

    it 'builds a single lower bound from an endless Range' do
      expect(bool_for(model.where(count: 3..)))
        .to eq({ filter: [{ range: { 'count' => { gte: 3 } } }] })
    end

    it 'builds a single upper bound from a beginless Range' do
      expect(bool_for(model.where(count: ..3)))
        .to eq({ filter: [{ range: { 'count' => { lte: 3 } } }] })
    end

    it 'builds an exclusive upper bound from an exclusive beginless Range' do
      expect(bool_for(model.where(count: ...3)))
        .to eq({ filter: [{ range: { 'count' => { lt: 3 } } }] })
    end

    it 'does not restrict anything for a totally unbounded Range' do
      # ActiveRecord reduces 'nil..nil' to a 'NOT IN ()', which excludes nothing.
      expect(bool_for(model.where(count: nil..nil))).to eq({})
    end

    it 'reduces a single-value Range to a term' do
      # ActiveRecord already reduces '5..5' to an Equality before it reaches the visitor
      expect(bool_for(model.where(count: 5..5)))
        .to eq({ filter: [{ term: { 'count' => 5 } }] })
    end

    it 'keeps ranges of different fields separate' do
      expect(bool_for(model.where(count: 1..5, name: 'alpha'..'gamma')))
        .to eq({ filter: [{ range: { 'count' => { gte: 1, lte: 5 } } },
                          { range: { 'name' => { gte: 'alpha', lte: 'gamma' } } }] })
    end

    it 'combines a range with a term' do
      expect(bool_for(model.where(count: 1...5, name: 'alpha')))
        .to eq({ filter: [{ range: { 'count' => { gte: 1, lt: 5 } } },
                          { term: { 'name' => 'alpha' } }] })
    end
  end

  describe 'generated query for a negation' do
    it 'negates a closed range' do
      expect(bool_for(model.where.not(count: 1..5)))
        .to eq({ must_not: [{ range: { 'count' => { gte: 1, lte: 5 } } }] })
    end

    it 'negates an exclusive range as ONE clause' do
      # IMPORTANT: 'NOT (gte 1 AND lt 5)' must NOT become 'NOT gte 1 AND NOT lt 5'
      expect(bool_for(model.where.not(count: 1...5)))
        .to eq({ must_not: [{ range: { 'count' => { gte: 1, lt: 5 } } }] })
    end

    it 'wraps a multi-clause negation into a nested bool' do
      # De Morgan: negating a conjunction may never be flattened into sibling +must_not+ clauses
      expect(bool_for(model.where.not(count: 1..5, name: 'alpha')))
        .to eq({ must_not: [{ bool: { filter: [{ range: { 'count' => { gte: 1, lte: 5 } } },
                                               { term: { 'name' => 'alpha' } }] } }] })
    end

    it 'inverts an endless range into a comparison' do
      # ActiveRecord inverts 'GreaterThanOrEqual' into 'LessThan' itself - no +Not+ node is build
      expect(bool_for(model.where.not(count: 3..)))
        .to eq({ filter: [{ range: { 'count' => { lt: 3 } } }] })
    end

    it 'still builds a term for a negated single value' do
      expect(bool_for(model.where.not(count: 3)))
        .to eq({ must_not: [{ term: { 'count' => 3 } }] })
    end
  end

  describe 'merging of bounds' do
    it 'merges an opposite lower & upper bound of the same field' do
      expect(bool_for(model.where(count: 1..).where(count: ..5)))
        .to eq({ filter: [{ range: { 'count' => { gte: 1, lte: 5 } } }] })
    end

    # IMPORTANT: merging two bounds of the SAME half would keep only one of them and therefore
    # silently WIDEN the query - 'gte 3 AND gte 1' would resolve everything from 1 upwards.
    it 'does NOT merge two lower bounds' do
      expect(bool_for(model.where(count: 3..).where(count: 1..)))
        .to eq({ filter: [{ range: { 'count' => { gte: 3 } } },
                          { range: { 'count' => { gte: 1 } } }] })
    end

    it 'does NOT merge two upper bounds' do
      expect(bool_for(model.where(count: ..3).where(count: ..5)))
        .to eq({ filter: [{ range: { 'count' => { lte: 3 } } },
                          { range: { 'count' => { lte: 5 } } }] })
    end

    it 'does NOT merge bounds of different fields' do
      expect(bool_for(model.where(count: 1..).where(name: ..'beta')))
        .to eq({ filter: [{ range: { 'count' => { gte: 1 } } },
                          { range: { 'name' => { lte: 'beta' } } }] })
    end
  end

  describe 'against the cluster' do
    it 'resolves an inclusive range' do
      expect(model.where(count: 1..3).pluck(:name)).to match_array(%w[alpha beta])
    end

    it 'resolves an exclusive range' do
      expect(model.where(count: 1...5).pluck(:name)).to match_array(%w[alpha beta])
    end

    it 'resolves an endless range' do
      expect(model.where(count: 3..).pluck(:name)).to match_array(%w[beta gamma])
    end

    it 'resolves a beginless range' do
      expect(model.where(count: ..3).pluck(:name)).to match_array(%w[alpha beta])
    end

    it 'resolves a negated range' do
      expect(model.where.not(count: 1..3).pluck(:name)).to eq(%w[gamma])
    end

    it 'resolves a totally unbounded range as "match all"' do
      expect(model.where(count: nil..nil).count).to eq(3)
    end

    it 'resolves the same records as the raw range escape hatch' do
      expect(model.where(count: 1...5).pluck(:name))
        .to match_array(model.filter(range: { count: { gte: 1, lt: 5 } }).pluck(:name))
    end

    it 'narrows - instead of widens - two lower bounds' do
      # the regression this guards: a naive merge kept just one bound and resolved 3 records
      expect(model.where(count: 3..).where(count: 1..).count).to eq(2)
    end

    it 'resolves a Date range' do
      expect(model.where(created_at: Date.new(2020, 6, 1)..Date.new(2022, 1, 1)).pluck(:name))
        .to eq(%w[beta])
    end

    it 'resolves a Time range' do
      expect(model.where(created_at: Time.utc(2021, 1, 1)..).pluck(:name))
        .to match_array(%w[beta gamma])
    end

    # Elasticsearch 8.16 switched the JDK locale database from COMPAT to CLDR, which changes every
    # TEXTUAL date format. Serializing strictly to ISO 8601 (which is what the JSON encoder of
    # 'elastic-transport' produces for a Date / Time / TimeWithZone) sidesteps that entirely.
    it 'serializes date bounds as ISO 8601 on the wire' do
      body = model.where(created_at: Date.new(2020, 1, 1)..Time.utc(2022, 6, 15, 10, 30)).to_query[:body]

      # assert on the ENCODED form - the body itself still carries the raw Ruby objects
      expect(JSON.parse(body.to_json)['query']['bool']['filter'][0]['range']['created_at'])
        .to eq({ 'gte' => '2020-01-01', 'lte' => '2022-06-15T10:30:00.000Z' })
    end

    it 'serializes a zoned Time with its offset' do
      zoned = ActiveSupport::TimeZone['Europe/Berlin'].local(2021, 6, 15, 10, 30)
      body  = model.where(created_at: zoned..).to_query[:body]

      expect(JSON.parse(body.to_json)['query']['bool']['filter'][0]['range']['created_at']['gte'])
        .to eq('2021-06-15T10:30:00.000+02:00')
    end
  end
end
