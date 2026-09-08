# frozen_string_literal: true

# Covers every class of the +ActiveRecord::ConnectionAdapters::Elasticsearch::Type+ namespace.
#
# These are the ES-specific ActiveModel types the adapter registers in its +TYPE_MAP+. They are
# plain Ruby - no cluster is involved, so every example works on the type object directly.
#
# The most important one is +MulticastValue+: Elasticsearch may return a single value OR an array
# for ANY mapping type, so +#lookup_multicast_cast_type+ wraps every resolved type into it.
#
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::Type
# see @ ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::TYPE_MAP
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::Type do
  # short-hand for the namespace - a +let+ instead of a constant, so the spec does not leak
  let(:types) { ActiveRecord::ConnectionAdapters::Elasticsearch::Type }

  #################
  # FORMAT STRING #
  #################

  # a String that is only kept when it matches the provided format - used for the 'ip' & 'version'
  # mapping types, which have a fixed shape
  describe ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString do
    subject(:type) { described_class.new }

    it 'is a :format_string' do
      expect(type.type).to eq(:format_string)
    end

    it 'defaults to a format that matches anything' do
      expect(type.format).to eq(/.*/)
      expect(type.cast('anything')).to eq('anything')
    end

    context 'with a provided format' do
      subject(:type) { described_class.new(format: /\A\d+\z/) }

      it 'exposes the format' do
        expect(type.format).to eq(/\A\d+\z/)
      end

      it 'keeps a matching value' do
        expect(type.cast('123')).to eq('123')
      end

      # a non-matching value is BLANKED - it is not nil, so the attribute stays present
      it 'blanks a non-matching value' do
        expect(type.cast('abc')).to eq('')
      end

      it 'blanks a partially matching value for an anchored format' do
        expect(type.cast('12a')).to eq('')
      end

      it 'keeps nil' do
        expect(type.cast(nil)).to be_nil
      end

      # only Strings are checked - everything else is passed through untouched
      it 'passes a non-String through' do
        expect(type.cast(123)).to eq(123)
      end
    end

    # +#match+ is not anchored on its own - an unanchored format matches anywhere in the value
    it 'matches anywhere for an unanchored format' do
      type = described_class.new(format: /\d+/)

      expect(type.cast('abc123def')).to eq('abc123def')
      expect(type.cast('abc')).to eq('')
    end

    # the :format option is removed before the remaining args reach ActiveRecord::Type::String
    it 'forwards the remaining arguments to the String type' do
      expect(described_class.new(format: /x/, limit: 5).limit).to eq(5)
    end

    it 'is registered for the elasticsearch adapter' do
      expect(ActiveRecord::Type.lookup(:format_string, adapter: :elasticsearch)).to be_a(described_class)
    end
  end

  ###################
  # NESTED & OBJECT #
  ###################

  # both only cast to a Hash - they exist so the mapping type survives into the schema dump
  {
    ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Nested => :nested,
    ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object => :object
  }.each do |klass, type_name|
    describe klass do
      subject(:type) { klass.new }

      it "is a :#{type_name}" do
        expect(type.type).to eq(type_name)
      end

      it 'keeps a Hash' do
        expect(type.cast({ 'a' => 1 })).to eq({ 'a' => 1 })
      end

      it 'casts an Array of pairs into a Hash' do
        expect(type.cast([%w[a b]])).to eq({ 'a' => 'b' })
      end

      it 'keeps nil' do
        expect(type.cast(nil)).to be_nil
      end

      # CAVEAT: the cast is a bare +#to_h+ - anything that does not respond to it raises
      it 'raises for a value without a to_h' do
        expect { type.cast('nope') }.to raise_error(NoMethodError, /to_h/)
      end
    end
  end

  ###################
  # MULTICAST VALUE #
  ###################

  describe ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue do
    subject(:type) { described_class.new(nested_type: ActiveRecord::Type::Integer.new) }

    it 'exposes the nested type' do
      expect(type.nested_type).to be_a(ActiveRecord::Type::Integer)
    end

    # the type is transparent - it reports whatever it wraps
    it 'reports the type of the nested type' do
      expect(type.type).to eq(:integer)
    end

    it 'falls back to a plain value type' do
      expect(described_class.new.nested_type).to be_a(ActiveModel::Type::Value)
      expect(described_class.new.type).to be_nil
    end

    it 'delegates user_input_in_time_zone to the nested type' do
      type = described_class.new(nested_type: ActiveRecord::Type::DateTime.new)

      expect(type.user_input_in_time_zone('2024-01-01')).to be_a(Time)
    end

    # THE reason this type exists: Elasticsearch may answer with a single value or an array
    describe '#deserialize' do
      it 'deserializes a single value' do
        expect(type.deserialize('5')).to eq(5)
      end

      it 'deserializes every element of an Array' do
        expect(type.deserialize(%w[5 6])).to eq([5, 6])
      end

      it 'deserializes every value of a Hash' do
        expect(type.deserialize({ 'a' => '5' })).to eq({ 'a' => 5 })
      end

      it 'keeps nil' do
        expect(type.deserialize(nil)).to be_nil
      end

      it 'keeps an empty Array' do
        expect(type.deserialize([])).to eq([])
      end

      # in some cases the ES type simply does not match the value - the raw value is kept instead
      # of blowing up
      it 'falls back to the raw value when the nested type cannot deserialize' do
        type = described_class.new(nested_type: ActiveRecord::Type::Date.new)

        expect(type.deserialize({ 'a' => 1 })).to eq({ 'a' => 1 })
      end

      # an :object nested type must NOT be split up - the Hash IS the value
      it 'does not walk into a Hash for an object nested type' do
        type = described_class.new(nested_type: ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object.new)

        expect(type.deserialize({ 'a' => 1 })).to eq({ 'a' => 1 })
      end

      it 'keeps an Array of objects for an object nested type' do
        type = described_class.new(nested_type: ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object.new)

        expect(type.deserialize([{ 'a' => 1 }])).to eq([{ 'a' => 1 }])
      end
    end

    it 'is registered for the elasticsearch adapter' do
      expect(ActiveRecord::Type.lookup(:multicast_value, adapter: :elasticsearch)).to be_a(described_class)
    end
  end

  #########
  # RANGE #
  #########

  # Elasticsearch range mappings ('integer_range', 'date_range', ...) return a {gte:, lte:} Hash -
  # this type turns it into a real ruby Range
  describe ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range do
    subject(:type) { described_class.new(nested_type: ActiveRecord::Type::Integer.new) }

    # the type name is composed from the nested type
    it 'composes the type name from the nested type' do
      expect(type.type).to eq(:range_integer)
      expect(described_class.new(nested_type: ActiveRecord::Type::Date.new).type).to eq(:range_date)
    end

    it 'is a MulticastValue' do
      expect(type).to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue)
    end

    describe '#deserialize' do
      it 'builds an inclusive range from gte & lte' do
        expect(type.deserialize({ 'gte' => 1, 'lte' => 5 })).to eq(1..5)
      end

      # the exclusive bounds are shifted by one, so the range stays inclusive
      it 'shifts the exclusive gt & lt bounds' do
        expect(type.deserialize({ 'gt' => 1, 'lt' => 5 })).to eq(2..4)
      end

      it 'mixes an exclusive with an inclusive bound' do
        expect(type.deserialize({ 'gt' => 1, 'lte' => 5 })).to eq(2..5)
      end

      # CAVEAT: a half-open range is NOT supported - it collapses to the empty (0..0) range
      it 'returns (0..0) for a missing upper bound' do
        expect(type.deserialize({ 'gte' => 1 })).to eq(0..0)
      end

      it 'returns (0..0) for a missing lower bound' do
        expect(type.deserialize({ 'lte' => 5 })).to eq(0..0)
      end

      it 'returns (0..0) for an empty Hash' do
        expect(type.deserialize({})).to eq(0..0)
      end

      it 'returns (0..0) for a non-Hash value' do
        expect(type.deserialize('nope')).to eq(0..0)
      end

      it 'keeps nil' do
        expect(type.deserialize(nil)).to be_nil
      end
    end

    it 'is registered for the elasticsearch adapter' do
      expect(ActiveRecord::Type.lookup(:range, adapter: :elasticsearch)).to be_a(described_class)
    end
  end

  ##############
  # TYPE MAP   #
  ##############

  # the mapping types the adapter resolves through these classes
  describe 'the adapters TYPE_MAP' do
    subject(:type_map) { ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::TYPE_MAP }

    {
      'object'        => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object,
      'nested'        => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Nested,
      'integer_range' => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range,
      'float_range'   => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range,
      'long_range'    => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range,
      'double_range'  => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range,
      'date_range'    => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range,
      'ip_range'      => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range,
      'ip'            => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString,
      'version'       => ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString
    }.each do |mapping_type, klass|
      it "resolves '#{mapping_type}' through #{klass.name.demodulize}" do
        expect(type_map.lookup(mapping_type)).to be_a(klass)
      end
    end

    it 'resolves the range type names from their nested type' do
      expect(type_map.lookup('integer_range').type).to eq(:range_integer)
      expect(type_map.lookup('date_range').type).to eq(:range_datetime)
    end

    # the 'ip' format only keeps a valid IPv4 address
    it 'blanks an invalid ip' do
      ip = type_map.lookup('ip')

      expect(ip.cast('192.168.0.1')).to eq('192.168.0.1')
      expect(ip.cast('999.999.999.999')).to eq('')
    end

    it 'blanks an invalid version' do
      version = type_map.lookup('version')

      expect(version.cast('1.2.3')).to eq('1.2.3')
      expect(version.cast('1.2')).to eq('')
    end
  end
end
