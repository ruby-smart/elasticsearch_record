# frozen_string_literal: true

# Specs for +ElasticsearchRecord::Relation::ValueMethods#limit_value=+.
#
# Elasticsearch caps a search without an explicit +size+ at 10 hits, which does not match
# what a SQL-minded caller expects from an unlimited relation. The setter therefore accepts
# two magic values (+'__max__'+ & +Float::INFINITY+) that resolve to the indices
# +index.max_result_window+ - and, with +delegate_query_nil_limit+ enabled on the model,
# +nil+ resolves to it as well.
#
# The remaining +ValueMethods+ setters (+kind_value=+, +configure_value=+, +query_clause=+ &
# +aggs_clause=+) are covered through their chain methods in
# +spec/elasticsearch_record/relation/query_methods_chain_spec.rb+.
#
# see @ ElasticsearchRecord::Relation::ValueMethods#limit_value=
# see @ ElasticsearchRecord::ModelSchema::ClassMethods#max_result_window
RSpec.describe ElasticsearchRecord::Relation::ValueMethods, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+.
  before { TestIndex.create! }

  after do
    TestIndex.drop!
    TestIndex.drop!(small_window_index_name)
  end

  let(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'ValueMethodsSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # a second index, configured with a smaller +index.max_result_window+
  let(:small_window_index_name) { "#{TestIndex.name}_small_window" }

  # the default +index.max_result_window+ of an index that does not configure one
  let(:max_result_window) { 10_000 }

  describe '#limit_value=' do
    it 'keeps a provided integer' do
      expect(model.limit(5).limit_value).to eq(5)
    end

    # the setter only intercepts the three magic values - everything else goes to +super+
    # untouched (the sanitizing happens later, while building the query)
    it 'keeps a provided numeric string as-is' do
      expect(model.limit('5').limit_value).to eq('5')
    end

    it 'keeps a provided zero' do
      expect(model.limit(0).limit_value).to eq(0)
    end

    context "with '__max__'" do
      it 'resolves the max_result_window' do
        expect(model.limit('__max__').limit_value).to eq(max_result_window)
      end

      it 'sends the resolved value as the query size' do
        expect(model.limit('__max__').to_query[:body][:size]).to eq(max_result_window)
      end
    end

    context 'with Float::INFINITY' do
      it 'resolves the max_result_window' do
        expect(model.limit(Float::INFINITY).limit_value).to eq(max_result_window)
      end

      it 'sends the resolved value as the query size' do
        expect(model.limit(Float::INFINITY).to_query[:body][:size]).to eq(max_result_window)
      end
    end

    context 'with nil' do
      # +delegate_query_nil_limit+ defaults to false - a nil limit then stays nil, which
      # leaves the +size+ out of the query and lets Elasticsearch fall back to its own 10.
      context 'with a disabled delegate_query_nil_limit' do
        it 'keeps the nil' do
          expect(model.limit(nil).limit_value).to be_nil
        end

        it 'does not send a query size' do
          expect(model.limit(nil).to_query[:body]).to be_blank
        end
      end

      context 'with an enabled delegate_query_nil_limit' do
        before { model.delegate_query_nil_limit = true }

        it 'resolves the max_result_window' do
          expect(model.limit(nil).limit_value).to eq(max_result_window)
        end

        it 'sends the resolved value as the query size' do
          expect(model.limit(nil).to_query[:body][:size]).to eq(max_result_window)
        end

        # the flag only affects an EXPLICIT +limit(nil)+ - the setter is never called for a
        # relation that simply has no limit, so those queries stay without a +size+.
        it 'does not affect a relation without a limit' do
          expect(model.all.limit_value).to be_nil
          expect(model.all.to_query[:body]).to be_blank
        end

        it 'still resolves a previously assigned limit' do
          expect(model.limit(5).limit(nil).limit_value).to eq(max_result_window)
        end
      end
    end

    # the resolution reads the CURRENT index setting - it is not a hardcoded 10_000
    context 'with a custom index.max_result_window' do
      let(:small_window) { 25 }

      let(:small_model) do
        TestIndex.create!(small_window_index_name) do |t|
          t.mapping :name, :keyword

          t.setting 'index.max_result_window', small_window
          t.setting 'index.number_of_shards', '1'
          t.setting 'index.number_of_replicas', '0'
        end

        Class.new(ElasticsearchRecord::Base) {
          def self.name = 'ValueMethodsSmallWindowSpecModel'
        }.tap { |klass|
          klass.table_name = small_window_index_name
          klass.reset_column_information
        }
      end

      it 'resolves the configured window' do
        expect(small_model.limit('__max__').limit_value).to eq(small_window)
      end

      it 'resolves the configured window for a nil limit' do
        small_model.delegate_query_nil_limit = true

        expect(small_model.limit(nil).limit_value).to eq(small_window)
      end
    end

    # +super+ still runs +assert_modifiable!+ - a loaded relation cannot be re-limited,
    # not even through a magic value.
    context 'with an already loaded relation' do
      subject(:relation) { model.all.tap(&:load) }

      it 'raises for a regular limit' do
        expect { relation.limit_value = 5 }.to raise_error(ActiveRecord::UnmodifiableRelation)
      end

      it 'raises for a magic limit' do
        expect { relation.limit_value = '__max__' }.to raise_error(ActiveRecord::UnmodifiableRelation)
      end
    end

    # +unscope+ deletes the value straight from +@values+ and never reaches the setter -
    # so an unscoped limit stays nil, even with an enabled delegation.
    it 'is bypassed by #unscope' do
      model.delegate_query_nil_limit = true

      expect(model.limit(5).unscope(:limit).limit_value).to be_nil
    end
  end
end
