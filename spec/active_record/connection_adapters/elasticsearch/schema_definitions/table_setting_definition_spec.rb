# frozen_string_literal: true

# Covers +ActiveRecord::ConnectionAdapters::Elasticsearch::TableSettingDefinition+.
#
# A setting definition is a name/value pair of a single index setting. It knows THREE things:
#
# - how the name flattens (a Hash value is expanded into dotted +flat_names+)
# - which class the setting belongs to (+final?+ / +static?+ / +dynamic?+)
# - whether it may be applied to the index in its current state (the validations)
#
# The name classes are matched against the dot-separated PARENTS of a name, so the constants act as
# modules: an entry matches when it IS the name or is one of its parents. That lets a nested name
# ('translog.durability') and a prefixed one ('index.number_of_replicas', whose 'index.' namespace
# is stripped first) resolve to their module, without matching a name that merely CONTAINS one
# ('research' is not a 'search' setting). Where several lists match, the MOST SPECIFIC entry wins
# (see the examples below).
#
# The class is plain Ruby - no cluster is involved. The index state is injected through
# +#with_state+ (see @ AttributeMethods), which is what +TableDefinition#new_setting_definition+
# does before handing the definition to the caller.
#
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::TableSettingDefinition
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::TableSettingDefinition do
  subject(:definition) { described_class.new('number_of_replicas', 2) }

  ##############
  # ATTRIBUTES #
  ##############

  describe '#initialize' do
    it 'exposes the name & value' do
      expect(definition.name).to eq('number_of_replicas')
      expect(definition.value).to eq(2)
    end

    # the name is ALWAYS stored as a String - the matchers do String comparisons
    it 'casts the name to a String' do
      expect(described_class.new(:refresh_interval, '1s').name).to eq('refresh_interval')
    end

    it 'keeps the value untouched' do
      expect(described_class.new('blocks', { read_only: true }).value).to eq({ read_only: true })
      expect(described_class.new('refresh_interval', nil).value).to be_nil
    end

    it 'has no state' do
      expect(definition.state?).to be(false)
      expect(definition.state).to be_nil
    end
  end

  describe '#with_state' do
    it 'assigns the state & returns itself' do
      expect(definition.with_state({ status: 'open' })).to be(definition)
      expect(definition.state).to eq({ status: 'open' })
      expect(definition.state?).to be(true)
    end

    # +state?+ is a +present?+ check - an empty Hash counts as NO state
    it 'ignores a blank state' do
      expect(definition.with_state({}).state?).to be(false)
    end
  end

  ###################
  # CLASS  MATCHERS #
  ###################

  describe '.match_ignore_names?' do
    # these are returned by the settings API but cannot be sent back to it
    it 'matches the internal names' do
      described_class::IGNORE_NAMES.each do |name|
        expect(described_class.match_ignore_names?(name)).to be(true)
      end
    end

    # +match_ignore_names?+ is still a CONTAINS check, so the API-prefixed name is caught as well
    it 'matches a prefixed name' do
      expect(described_class.match_ignore_names?('index.provided_name')).to be(true)
    end

    it 'does not match a regular setting' do
      expect(described_class.match_ignore_names?('number_of_replicas')).to be(false)
    end
  end

  describe '.match_valid_names?' do
    it 'matches every final, static & dynamic name' do
      described_class::VALID_NAMES.each do |name|
        expect(described_class.match_valid_names?(name)).to be(true)
      end
    end

    it 'is the union of the three name lists' do
      expect(described_class::VALID_NAMES).to eq(
        described_class::FINAL_NAMES + described_class::STATIC_NAMES + described_class::DYNAMIC_NAMES
      )
    end

    it 'matches a nested name through its module' do
      expect(described_class.match_valid_names?('translog.durability')).to be(true)
      expect(described_class.match_valid_names?('analysis.analyzer.custom.type')).to be(true)
    end

    it 'does not match an unknown name' do
      expect(described_class.match_valid_names?('nonsense')).to be(false)
    end
  end

  describe '.match_final_names?' do
    it 'matches the final names' do
      expect(described_class.match_final_names?('number_of_shards')).to be(true)
      expect(described_class.match_final_names?('soft_deletes.enabled')).to be(true)
    end

    it 'does not match a static or dynamic name' do
      expect(described_class.match_final_names?('codec')).to be(false)
      expect(described_class.match_final_names?('number_of_replicas')).to be(false)
    end
  end

  describe '.match_static_names?' do
    it 'matches the static names' do
      expect(described_class.match_static_names?('codec')).to be(true)
      expect(described_class.match_static_names?('shard.check_on_startup')).to be(true)
    end

    it 'matches a nested name of a static module' do
      expect(described_class.match_static_names?('merge.scheduler.max_thread_count')).to be(true)
    end

    it 'does not match a dynamic name' do
      expect(described_class.match_static_names?('refresh_interval')).to be(false)
    end
  end

  describe '.match_dynamic_names?' do
    it 'matches the dynamic names' do
      expect(described_class.match_dynamic_names?('number_of_replicas')).to be(true)
      expect(described_class.match_dynamic_names?('search.idle.after')).to be(true)
    end

    it 'matches a nested name of a dynamic module' do
      expect(described_class.match_dynamic_names?('blocks.read_only')).to be(true)
      expect(described_class.match_dynamic_names?('translog.durability')).to be(true)
    end

    it 'does not match a final name' do
      expect(described_class.match_dynamic_names?('number_of_shards')).to be(false)
    end
  end

  # the matchers resolve a name against its dot-separated parents - an entry matches when it IS the
  # name or is one of its modules. A name that merely CONTAINS a known one is NOT matched.
  describe 'the matching rules' do
    it 'does not match a name that only contains a known name' do
      # 'research' contains - but is not nested under - the static module 'search'
      expect(described_class.match_static_names?('research')).to be(false)
      expect(described_class.match_valid_names?('research')).to be(false)
    end

    it 'does not match a partial path segment' do
      # 'searchable.foo' starts with 'search', but not with the module 'search.'
      expect(described_class.match_valid_names?('searchable.foo')).to be(false)
    end

    it 'resolves the most specific entry when several lists match' do
      # 'search.idle.after' is nested under the STATIC module 'search', but is itself listed as
      # DYNAMIC - the longer (more specific) entry has to win, otherwise the setting could never
      # be changed on an open index
      expect(described_class.match_dynamic_names?('search.idle.after')).to be(true)
      expect(described_class.match_static_names?('search.idle.after')).to be(false)
    end

    it 'strips a leading "index." namespace' do
      expect(described_class.match_dynamic_names?('index.number_of_replicas')).to be(true)
      expect(described_class.match_final_names?('index.number_of_shards')).to be(true)
    end

    it 'matches the modern mapping & lifecycle settings' do
      expect(described_class.match_dynamic_names?('mapping.total_fields.limit')).to be(true)
      expect(described_class.match_dynamic_names?('lifecycle.name')).to be(true)
      # the '_source' mode is fixed at creation time
      expect(described_class.match_static_names?('mapping.source.mode')).to be(true)
    end

    it 'matches an ignored name as valid, too' do
      # 'routing.allocation.initial_recovery' is ignored, but is nested under the static module 'routing' -
      # the caller therefore has to check +match_ignore_names?+ FIRST
      # see @ CreateTableDefinition#from_state
      expect(described_class.match_ignore_names?('routing.allocation.initial_recovery')).to be(true)
      expect(described_class.match_valid_names?('routing.allocation.initial_recovery')).to be(true)
    end
  end

  ##############
  # FLAT NAMES #
  ##############

  describe '#flat_names' do
    it 'is the name itself for a scalar value' do
      expect(definition.flat_names).to eq(['number_of_replicas'])
    end

    it 'is the name itself for an Array value' do
      expect(described_class.new('query.default_field', %w[a b]).flat_names).to eq(['query.default_field'])
    end

    it 'is the name itself for a nil value' do
      expect(described_class.new('refresh_interval', nil).flat_names).to eq(['refresh_interval'])
    end

    it 'expands a Hash value into dotted names' do
      expect(described_class.new('translog', { durability: 'async', sync_interval: '30s' }).flat_names)
        .to eq(['translog.durability', 'translog.sync_interval'])
    end

    it 'expands a deeply nested Hash value' do
      expect(described_class.new('analysis', { analyzer: { custom: { type: 'keyword' } } }).flat_names)
        .to eq(['analysis.analyzer.custom.type'])
    end

    # an empty Hash produces NO names at all - see the +all?+ note on the class predicates below
    it 'is empty for an empty Hash value' do
      expect(described_class.new('translog', {}).flat_names).to eq([])
    end

    it 'is memoized' do
      expect(definition.flat_names).to be(definition.flat_names)
    end
  end

  ####################
  # CLASS PREDICATES #
  ####################

  describe '#final?' do
    it 'is true for a final name' do
      expect(described_class.new('number_of_shards', 1).final?).to be(true)
    end

    it 'is false for a static or dynamic name' do
      expect(described_class.new('codec', 'best_compression').final?).to be(false)
      expect(described_class.new('number_of_replicas', 2).final?).to be(false)
    end

    # ALL flat names have to match - a Hash mixing a final with a dynamic name is not final
    it 'is false when only some of the flat names are final' do
      expect(described_class.new('index', { number_of_shards: 1, number_of_replicas: 2 }).final?).to be(false)
    end

    it 'is memoized' do
      setting = described_class.new('number_of_shards', 1)

      expect(setting.final?).to be(true)

      # the memo (and the flat names) survive a later name change - a definition is not meant to be
      # re-used with a different name
      setting.name = 'refresh_interval'
      expect(setting.final?).to be(true)
    end
  end

  describe '#static?' do
    it 'is true for a static name' do
      expect(described_class.new('codec', 'best_compression').static?).to be(true)
      expect(described_class.new('merge', { scheduler: { max_thread_count: 1 } }).static?).to be(true)
    end

    it 'is false for a final or dynamic name' do
      expect(described_class.new('number_of_shards', 1).static?).to be(false)
      expect(described_class.new('refresh_interval', '1s').static?).to be(false)
    end
  end

  describe '#dynamic?' do
    it 'is true for a dynamic name' do
      expect(described_class.new('number_of_replicas', 2).dynamic?).to be(true)
      expect(described_class.new('translog', { durability: 'async' }).dynamic?).to be(true)
    end

    it 'is true for an API-prefixed dynamic name' do
      expect(described_class.new('index.number_of_replicas', 2).dynamic?).to be(true)
    end

    it 'is false for a final or static name' do
      expect(described_class.new('number_of_shards', 1).dynamic?).to be(false)
      expect(described_class.new('codec', 'best_compression').dynamic?).to be(false)
    end
  end

  # +all?+ on an EMPTY list is true, so a setting without any flat name reports every class
  it 'reports every class for an empty Hash value' do
    setting = described_class.new('translog', {})

    expect(setting.final?).to be(true)
    expect(setting.static?).to be(true)
    expect(setting.dynamic?).to be(true)
  end

  ###############
  # VALIDATIONS #
  ###############

  describe 'validations' do
    describe 'the name presence' do
      it 'is invalid without a name' do
        setting = described_class.new(nil, 1)

        expect(setting.valid?).to be(false)
        expect(setting.error_messages).to eq("Name can't be blank")
      end
    end

    describe '#_validate_name' do
      it 'is valid for a known name' do
        expect(definition.valid?).to be(true)
        expect(definition.error_messages).to eq('')
      end

      it 'is invalid for an unknown name' do
        setting = described_class.new('nonsense', 1)

        expect(setting.valid?).to be(false)
        expect(setting.error_messages).to eq('Name is invalid!')
      end

      # every flat name is checked - one unknown leaf invalidates the whole setting. Note that a
      # leaf below a KNOWN module ('translog.nonsense') still passes - it contains the module name.
      it 'is invalid when a nested name is unknown' do
        setting = described_class.new('index', { number_of_replicas: 2, nonsense: true })

        expect(setting.flat_names).to eq(['index.number_of_replicas', 'index.nonsense'])
        expect(setting.valid?).to be(false)
        expect(setting.error_messages).to eq('Name is invalid!')
      end
    end

    describe '#_validate_final_name' do
      let(:setting) { described_class.new('number_of_shards', 1) }

      # no state at all is treated like a missing index - the definition is being CREATED
      it 'is valid without a state' do
        expect(setting.valid?).to be(true)
      end

      it 'is valid on a missing index' do
        expect(setting.with_state({ status: 'missing' }).valid?).to be(true)
      end

      it 'is invalid on an existing index' do
        setting.with_state({ status: 'open' })

        expect(setting.valid?).to be(false)
        expect(setting.error_messages).to eq('Name is final - this setting can only be set at index creation time!')
      end

      # unlike a static setting, a final one cannot even be changed on a CLOSED index
      it 'is invalid on a closed index' do
        setting.with_state({ status: 'close' })

        expect(setting.valid?).to be(false)
        expect(setting.error_messages).to eq('Name is final - this setting can only be set at index creation time!')
      end
    end

    describe '#_validate_static_name' do
      let(:setting) { described_class.new('codec', 'best_compression') }

      it 'is valid without a state' do
        expect(setting.valid?).to be(true)
      end

      it 'is valid on a missing index' do
        expect(setting.with_state({ status: 'missing' }).valid?).to be(true)
      end

      it 'is valid on a closed index' do
        expect(setting.with_state({ status: 'close' }).valid?).to be(true)
      end

      it 'is invalid on an open index' do
        setting.with_state({ status: 'open' })

        expect(setting.valid?).to be(false)
        expect(setting.error_messages).to eq('Name is static - this setting can only be changed on a closed index!')
      end
    end

    describe 'a dynamic name' do
      it 'is valid in every state' do
        %w[missing close open].each do |status|
          setting = described_class.new('number_of_replicas', 2).with_state({ status: status })

          expect(setting.valid?).to be(true)
        end
      end
    end

    # +error_messages+ (see @ AttributeMethods) joins every message - an empty Hash value hits both
    # the final AND the static validation
    it 'joins multiple errors' do
      setting = described_class.new('translog', {}).with_state({ status: 'open' })

      expect(setting.valid?).to be(false)
      expect(setting.error_messages).to eq(
        'Name is final - this setting can only be set at index creation time!, ' \
          'Name is static - this setting can only be changed on a closed index!'
      )
    end
  end
end
