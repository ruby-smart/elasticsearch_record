# frozen_string_literal: true

module ElasticsearchRecord
  class ModelApi
    attr_reader :klass

    def initialize(klass)
      @klass = klass
    end

    # delegated dangerous methods (created with exclamation mark)
    # not able to provide individual arguments - always the defaults will be used!
    #
    # @example
    #   open!
    #   close!
    #   refresh!
    #   block!
    #   unblock!
    %w(open close refresh block unblock).each do |method|
      define_method("#{method}!") do
        _connection.send("#{method}_table", _index_name)
      end
    end

    # delegated dangerous methods with args
    #
    # @example
    #   create!(:new_table_name, settings: , mappings:, alias: , ...)
    #   clone!(:new_table_name)
    #   rename!(:new_table_name)
    #   backup!(to: :backup_name)
    #   restore!(from: :backup_name)
    #   reindex!(:new_table_name)
    %w(create clone rename backup restore reindex).each do |method|
      define_method("#{method}!") do |*args|
        _connection.send("#{method}_table", _index_name, *args)
      end
    end

    # delegated dangerous methods with confirm parameter (created with exclamation mark)
    # a exception will be raised, if +confirm:true+ is missing.
    #
    # @example
    #   drop!(confirm: true)
    #   truncate!(confirm: true)
    %w(drop truncate).each do |method|
      define_method("#{method}!") do |confirm: false|
        raise "#{method} of table '#{_index_name}' aborted!\nexecution not confirmed!\ncall with: #{klass}.api.#{method}!(confirm: true)" unless confirm
        _connection.send("#{method}_table", _index_name)
      end
    end

    # delegated table methods
    #
    # @example
    #   mappings
    #   metas
    #   settings
    #   aliases
    #   state
    #   schema
    #   exists?
    %w(mappings metas settings aliases state schema exists?).each do |method|
      define_method(method) do |*args|
        _connection.send("table_#{method}", _index_name, *args)
      end
    end

    # delegated plain methods
    #
    # @example
    #   alias_exists?
    #   setting_exists?
    #   mapping_exists?
    #   meta_exists?
    %w(alias_exists? setting_exists? mapping_exists? meta_exists?).each do |method|
      define_method(method) do |*args|
        _connection.send(method, _index_name, *args)
      end
    end

    # -- DYNAMIC METHOD DOCUMENTATION FOR YARD -------------------------------------------------------------------------

    # @!method open!
    # Shortcut to open the closed index.
    # @return [Boolean] acknowledged status

    # @!method close!
    # Shortcut to close the opened index.
    # @return [Boolean] acknowledged status

    # @!method refresh!
    # Shortcut to refresh the index.
    # @return [Boolean] result state (returns false if refreshing failed)

    # @!method block!
    # Shortcut to block write access on the index
    # @return [Boolean] acknowledged status

    # @!method unblock!
    # Shortcut to unblock all blocked accesses on the index
    # @return [Boolean] acknowledged status

    # @!method drop!(confirm: false)
    # Shortcut to drop the index
    # @param confirm
    # @return [Boolean] acknowledged status

    # @!method truncate!(confirm: false)
    # Shortcut to truncate the index
    # @param confirm
    # @return [Boolean] acknowledged status

    # @!method mappings
    # Shortcut for mappings
    # @return [Hash]

    # @!method metas
    # Shortcut for metas
    # @return [Hash]

    # @!method settings(flat_settings=true)
    # Shortcut for settings
    # @param [Boolean] flat_settings (default: true)
    # @return [Hash]

    # @!method aliases
    # Shortcut for aliases
    # @return [Hash]

    # @!method state
    # Shortcut for state
    # @return [Hash]

    # @!method schema(features=[])
    # Shortcut for schema
    # @param [Array, Symbol] features
    # @return [Hash]

    # @!method exists?
    # Shortcut for exists
    # @return [Boolean]

    # @!method alias_exists?
    # Shortcut for alias_exists
    # @return [Boolean]

    # @!method setting_exists?
    # Shortcut for setting_exists
    # @return [Boolean]

    # @!method mapping_exists?
    # Shortcut for mapping_exists
    # @return [Boolean]

    # @!method meta_exists?
    # Shortcut for meta_exists
    # @return [Boolean]

    # @!method create!(force: false, copy_from: nil, if_not_exists: false, **options)
    # Shortcut for create_table
    # @param [Boolean] force
    # @param [nil, String] copy_from
    # @param [Hash] options
    # @return [Boolean] acknowledged status

    # @!method clone!(target_name, **options)
    # Shortcut for clone_table
    # @param [String] target_name
    # @param [Hash] options
    # @return [Boolean]

    # @!method rename!(target_name, timeout: nil, **options)
    # Shortcut for rename_table
    # @param [String] target_name
    # @param [String (frozen)] timeout
    # @param [Hash] options

    # @!method backup!(to: nil, close: true)
    # Shortcut for backup_table
    # @param [String] to
    # @param [Boolean] close
    # @return [String] backup_name

    # @!method restore!(from:, timeout: nil, open: true, drop_backup: false)
    # Shortcut for restore_table
    # @param [String] from
    # @param [String (frozen)] timeout
    # @param [Boolean] open
    # @return [Boolean] acknowledged status

    # @!method reindex!(target_name, **options)
    # Shortcut for reindex_table
    # @param [String] target_name
    # @param [Hash] options
    # @return [Hash] reindex stats

    # fast insert/update data.
    # IMPORTANT: Any 'doc'-id must by provided with underscore '_' ( +:_id+ )
    #
    # @example
    #   index([{name: 'Hans', age: 34}, {name: 'Peter', age: 22}])
    #
    #   index({_id: 5, name: 'Georg', age: 87})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def index(data, **options)
      bulk(data, :index, **options)
    end

    # fast insert new data.
    # IMPORTANT: Any 'doc'-id must by provided with underscore '_' ( +:_id+ )
    #
    # @example
    #   insert([{name: 'Hans', age: 34}, {name: 'Peter', age: 22}])
    #
    #   insert({name: 'Georg', age: 87})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def insert(data, **options)
      bulk(data, :create, **options)
    end

    # fast update existing data.
    # IMPORTANT: Any 'doc'-id must by provided with underscore '_' ( +:_id+ )
    #
    # @example
    #   update([{_id: 1, name: 'Hansi'}, {_id: 2, name: 'Peter Parker', age: 42}])
    #
    #   update({_id: 3, name: 'Georg McCain'})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def update(data, **options)
      bulk(data, :update, **options)
    end

    # fast delete data.
    # IMPORTANT: Any 'doc'-id must by provided with underscore '_' ( +:_id+ )
    #
    # @example
    #   delete([1,2,3,5])
    #
    #   delete(3)
    #
    #   delete({_id: 2})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def delete(data, **options)
      data = [data] unless data.is_a?(Array)

      if data[0].is_a?(Hash)
        bulk(data, :delete, **options)
      else
        bulk(data.map { |id| { _id: id } }, :delete, **options)
      end
    end

    # bulk handle provided data (single Hash or multiple Array<Hash>).
    # @param [Hash,Array<Hash<Symbol=>Object>>] data - the data to insert/update/delete ...
    # @param [Symbol] operation
    # @param [Boolean, Symbol] refresh
    def bulk(data, operation = :index, refresh: true, **options)
      data = [data] unless data.is_a?(Array)

      _connection.api(:core, :bulk, {
        index:   _index_name,
        body:    case operation
                 when :update
                   data.map { |item| { update: { _id: (item[:_id].presence || item['_id']), data: { doc: item.except(:_id, '_id') } } } }
                 when :delete
                   data.map { |item| { delete: { _id: (item[:_id].presence || item['_id']) } } }
                 else
                   data.map { |item| { operation => { _id: (item[:_id].presence || item['_id']), data: item.except(:_id, '_id') } } }
                 end,
        refresh: refresh
      }, "BULK #{operation.to_s.upcase}", **options)
    end

    private

    def _index_name
      klass.index_name
    end

    def _connection
      klass.connection
    end
  end
end