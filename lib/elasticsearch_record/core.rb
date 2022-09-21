module ElasticsearchRecord
  module Core
    extend ActiveSupport::Concern

    module ClassMethods

      private

      # creates a new relation object.
      # This is a 1:1 copy but with a different relation klass
      # # @see ActiveRecord::Core::ClassMethods#relation
      def relation
        relation = super
        # sucks, but there is no other solution yet to NOT mess with
        # ActiveRecord::Delegation::DelegateCache#initialize_relation_delegate_cache
        relation.extend ElasticsearchRecord::Extensions::Relation
        relation
      end
    end
  end
end




