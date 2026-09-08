# frozen_string_literal: true

# Specs for the +id+-related overrides of +ElasticsearchRecord::Core+.
#
# Elasticsearch stores the document key in the virtual +_id+ metadata field, but an index may
# ALSO carry a regular +id+ mapping - two different things that Rails cannot tell apart, since it
# funnels every primary_key access through +#id+ / +#id=+.
#
# The concern resolves this with two separate mechanisms, and the difference between them is the
# point of these specs:
#
# * +#id+, +#id=+ & +#id_was+ honour the +delegate_id_attribute+ flag - only with the flag enabled
#   do they address the 'id'-ATTRIBUTE instead of the primary_key.
# * +#write_attribute+ & +#read_attribute+ do NOT check the flag - they always address the
#   'id'-attribute when the model has one.
#
# So a model with a disabled delegation resolves +#id+ from the document +_id+ while
# +#read_attribute('id')+ resolves the mapped field - both at the same time, by design.
#
# see @ ElasticsearchRecord::Core
RSpec.describe ElasticsearchRecord::Core, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+.
  before do
    TestIndex.create!

    # an index that carries a REGULAR 'id' mapping next to the virtual '_id'
    TestIndex.create!(id_index_name) do |t|
      t.mapping :id, :keyword
      t.mapping :name, :keyword
    end
  end

  after do
    TestIndex.drop!
    TestIndex.drop!(id_index_name)
    TestIndex.drop!(pk_index_name)
  end

  let(:id_index_name) { "#{TestIndex.name}_ids" }
  let(:pk_index_name) { "#{TestIndex.name}_pk" }

  # builds a model against the provided index.
  def build_model(index_name, model_name, delegate_id_attribute: false)
    Class.new(ElasticsearchRecord::Base).tap { |klass|
      klass.define_singleton_method(:name) { model_name }
      klass.table_name            = index_name
      klass.delegate_id_attribute = delegate_id_attribute
      klass.reset_column_information
    }
  end

  # has an 'id' mapping & resolves it through +#id+ (delegation ENABLED)
  let(:delegated_model) { build_model(id_index_name, 'CoreDelegatedSpecModel', delegate_id_attribute: true) }

  # has an 'id' mapping, but resolves the document '_id' through +#id+ (delegation DISABLED)
  let(:undelegated_model) { build_model(id_index_name, 'CoreUndelegatedSpecModel') }

  # has NO 'id' mapping - its primary_key is the virtual '_id'
  let(:plain_model) { build_model(TestIndex.name, 'CorePlainSpecModel') }

  # has NO 'id' mapping, but an enabled delegation - the flag must stay without effect
  let(:delegated_plain_model) { build_model(TestIndex.name, 'CoreDelegatedPlainSpecModel', delegate_id_attribute: true) }

  # has NO 'id' mapping and a primary_key that is a REAL field ('uuid')
  let(:pk_model) do
    TestIndex.create!(pk_index_name) do |t|
      t.mapping :uuid, :keyword
      t.mapping :name, :keyword
      t.meta :primary_key, 'uuid'
    end

    build_model(pk_index_name, 'CorePkSpecModel')
  end

  # a persisted document that carries BOTH keys: the mapped 'id' field ('custom-1') and an
  # elasticsearch generated document '_id' - resolved through the UNDELEGATED model.
  #
  # PLEASE NOTE: it has to be CREATED through the delegated model - +#id=+ of the undelegated
  # model addresses the primary_key, so a +create!(id: 'custom-1')+ would assign the document
  # '_id' and leave the mapped field empty.
  let(:persisted_undelegated) do
    delegated_model.create!(id: 'custom-1', name: 'alpha')
    delegated_model.api.refresh!

    undelegated_model.first
  end

  #######
  # ID= #
  #######

  describe '#id=' do
    context 'with an enabled delegate_id_attribute' do
      subject(:record) { delegated_model.new(name: 'alpha') }

      it 'writes the id attribute' do
        record.id = 'custom-1'

        expect(record._read_attribute('id')).to eq('custom-1')
      end

      it 'resolves the written value through #id' do
        record.id = 'custom-1'

        expect(record.id).to eq('custom-1')
      end

      # the document key stays untouched - it is assigned by Elasticsearch on insert
      it 'does not touch the document _id' do
        record.id = 'custom-1'

        expect(record._id).to be_nil
      end

      it 'marks the id attribute as changed' do
        record.id = 'custom-1'

        expect(record.changes['id']).to eq([nil, 'custom-1'])
      end

      it 'does not mark the document _id as changed' do
        record.id = 'custom-1'

        expect(record.changes).not_to have_key('_id')
      end
    end

    # without the flag the 'id' mapping is a regular field - +#id=+ addresses the primary_key
    context 'with a disabled delegate_id_attribute' do
      subject(:record) { undelegated_model.new(name: 'alpha') }

      it 'writes the document _id' do
        record.id = 'doc-1'

        expect(record._id).to eq('doc-1')
      end

      it 'does not touch the id attribute' do
        record.id = 'doc-1'

        expect(record._read_attribute('id')).to be_nil
      end
    end

    # +delegate_id_attribute+ only delegates if the model HAS the attribute - an enabled flag
    # on an index without an 'id' mapping must not break the primary_key assignment.
    context 'with an enabled delegate_id_attribute but no id attribute' do
      subject(:record) { delegated_plain_model.new(name: 'alpha') }

      it 'writes the document _id' do
        record.id = 'doc-1'

        expect(record._id).to eq('doc-1')
      end
    end

    # a custom primary_key does not replace the document key - the '_id' is written
    # auxiliary, so the record still addresses the right document.
    context 'with a custom primary_key' do
      subject(:record) { pk_model.new(name: 'alpha') }

      it 'writes the primary_key attribute' do
        record.id = 'uuid-1'

        expect(record.uuid).to eq('uuid-1')
      end

      it 'auxiliary writes the document _id' do
        record.id = 'uuid-1'

        expect(record._id).to eq('uuid-1')
      end
    end

    context 'with the _id as primary_key' do
      subject(:record) { plain_model.new(name: 'alpha') }

      it 'writes the document _id' do
        record.id = 'doc-1'

        expect(record._id).to eq('doc-1')
      end
    end
  end

  ##########
  # ID_WAS #
  ##########

  describe '#id_was' do
    context 'with an enabled delegate_id_attribute' do
      subject(:record) { delegated_model.create!(id: 'custom-1', name: 'alpha') }

      it 'returns the previous id attribute' do
        record.id = 'custom-2'

        expect(record.id_was).to eq('custom-1')
      end

      it 'returns the current value while unchanged' do
        expect(record.id_was).to eq('custom-1')
      end

      # +#write_attribute+ writes the same attribute, so it is tracked identically
      it 'tracks a change made through #write_attribute' do
        record.write_attribute('id', 'custom-2')

        expect(record.id_was).to eq('custom-1')
      end

      it 'resolves the same value as #attribute_was' do
        record.id = 'custom-2'

        expect(record.id_was).to eq(record.attribute_was('id'))
      end
    end

    context 'with a disabled delegate_id_attribute' do
      subject(:record) { persisted_undelegated }

      # the primary_key is the document '_id' - NOT the (unchanged) 'id' attribute
      it 'returns the previous document _id' do
        previous  = record._id
        record.id = 'doc-2'

        expect(record.id_was).to eq(previous)
      end

      it 'does not return the id attribute' do
        expect(record.id_was).to eq(record._id)
        expect(record.id_was).not_to eq('custom-1')
      end
    end

    context 'with an enabled delegate_id_attribute but no id attribute' do
      subject(:record) { delegated_plain_model.create!(name: 'alpha') }

      it 'returns the previous document _id' do
        previous  = record._id
        record.id = 'doc-2'

        expect(record.id_was).to eq(previous)
      end
    end
  end

  ###################
  # WRITE_ATTRIBUTE #
  ###################

  # +ActiveRecord::AttributeMethods::Write#write_attribute+ rewrites a provided 'id' to the
  # models primary_key - which would write the document '_id' instead of the mapped field.
  # The override prevents this, INDEPENDENT of the +delegate_id_attribute+ flag.
  describe '#write_attribute' do
    context 'with an id attribute' do
      # the delegation flag must not make a difference here
      [true, false].each do |delegate|
        context "with a #{delegate ? 'enabled' : 'disabled'} delegate_id_attribute" do
          subject(:record) do
            build_model(id_index_name, "CoreWriteSpecModel#{delegate}", delegate_id_attribute: delegate)
              .new(name: 'alpha')
          end

          it 'writes the id attribute' do
            record.write_attribute('id', 'custom-1')

            expect(record._read_attribute('id')).to eq('custom-1')
          end

          it 'does not write the document _id' do
            record.write_attribute('id', 'custom-1')

            expect(record._id).to be_nil
          end

          it 'accepts a symbol' do
            record.write_attribute(:id, 'custom-1')

            expect(record._read_attribute('id')).to eq('custom-1')
          end
        end
      end
    end

    # without an 'id' mapping the call falls through to ActiveRecord, which resolves
    # 'id' to the primary_key ('_id')
    context 'without an id attribute' do
      subject(:record) { plain_model.new(name: 'alpha') }

      it 'writes the document _id' do
        record.write_attribute('id', 'doc-1')

        expect(record._id).to eq('doc-1')
      end
    end

    context 'with any other attribute' do
      subject(:record) { delegated_model.new }

      it 'writes the provided attribute' do
        record.write_attribute('name', 'alpha')

        expect(record.name).to eq('alpha')
      end
    end
  end

  ##################
  # READ_ATTRIBUTE #
  ##################

  describe '#read_attribute' do
    context 'with an id attribute' do
      [true, false].each do |delegate|
        context "with a #{delegate ? 'enabled' : 'disabled'} delegate_id_attribute" do
          # PLEASE NOTE: the record is seeded through +#write_attribute+, which ignores the
          # delegation as well - a +new(id: 'custom-1')+ would run through +#id=+ and assign
          # the document '_id' for the undelegated model.
          subject(:record) do
            build_model(id_index_name, "CoreReadSpecModel#{delegate}", delegate_id_attribute: delegate)
              .new(name: 'alpha').tap { |instance| instance.write_attribute('id', 'custom-1') }
          end

          it 'reads the id attribute' do
            expect(record.read_attribute('id')).to eq('custom-1')
          end

          it 'accepts a symbol' do
            expect(record.read_attribute(:id)).to eq('custom-1')
          end

          # the attribute is present, so the (forwarded) block is never called
          it 'does not call a provided block' do
            expect(record.read_attribute('id') { 'fallback' }).to eq('custom-1')
          end
        end
      end

      # THE point of the override: a disabled delegation splits the two accessors -
      # +#id+ resolves the document key while +#read_attribute+ resolves the mapped field.
      it 'does not resolve the same value as #id for a disabled delegation' do
        record = persisted_undelegated

        expect(record.read_attribute('id')).to eq('custom-1')
        expect(record.id).to eq(record._id)
        expect(record.id).not_to eq('custom-1')
      end

      it 'resolves the same value as #id for an enabled delegation' do
        record = delegated_model.create!(id: 'custom-1', name: 'alpha')

        expect(record.read_attribute('id')).to eq(record.id)
      end
    end

    # +#select+ resolves only the provided fields, so the 'id' attribute is not present on the
    # record - the call falls through to ActiveRecord, which yields the provided block.
    context 'without a resolved id attribute' do
      subject(:record) do
        delegated_model.create!(id: 'custom-1', name: 'alpha')
        delegated_model.api.refresh!

        delegated_model.select(:name).first
      end

      it 'has no id attribute' do
        expect(record.has_attribute?('id')).to be(false)
      end

      it 'calls a provided block' do
        expect(record.read_attribute('id') { |name| "missing #{name}" }).to eq('missing id')
      end
    end

    context 'without an id attribute' do
      subject(:record) { plain_model.create!(name: 'alpha') }

      # PLEASE NOTE: opposed to +#write_attribute+, ActiveRecords +#read_attribute+ does NOT
      # rewrite 'id' to the primary_key - so this resolves nothing, not the document '_id'.
      it 'does not read the document _id' do
        expect(record.read_attribute('id')).to be_nil
        expect(record._id).to be_present
      end
    end

    context 'with any other attribute' do
      subject(:record) { delegated_model.new(name: 'alpha') }

      it 'reads the provided attribute' do
        expect(record.read_attribute('name')).to eq('alpha')
      end
    end
  end
end
