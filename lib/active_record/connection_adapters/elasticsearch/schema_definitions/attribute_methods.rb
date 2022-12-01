# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module AttributeMethods
        extend ActiveSupport::Concern

        included do
          attr_reader :state

          def error_messages
            errors.full_messages.join(', ')
          end

          def with_state(state)
            @state = state

            self
          end

          def state?
            state.present?
          end

          private

          def __set_attribute(key, value)
            if value.nil?
              __remove_attribute(key)
            elsif value.is_a?(Array) || value.is_a?(Hash)
              @attributes[key] = value.compact
            else
              @attributes[key] = value
            end
          end

          def __get_attribute(key)
            @attributes[key]
          end

          def __remove_attribute(key)
            @attributes.delete(key)
          end

          def __set_nested(attr, key, value)
            values = self.send(attr).presence || {}

            if value.nil?
              values.delete(key)
            else
              values[key.to_s] = value
            end
            self.send("#{attr}=", values)
          end

          def __get_nested(attr, key)
            values = self.send(attr).presence || {}
            values[key.to_s]
          end

          def __attributes_keys
            @attributes.keys
          end

          def __attributes_values
            @attributes.values
          end

          def __assign(attributes)
            attributes.each do |key, value|
              send("#{key}=", value)
            end
          end

          def invalid!(message, key = :base)
            errors.add(key, message)
            false
          end
        end

        class_methods do
          def build_attribute_methods!(*args)
            opts       = args.extract_options!
            opts[:key] ||= :attributes

            args.each do |name|
              class_eval <<-CODE, __FILE__, __LINE__ + 1
                def #{name}
                  __get_attribute(:#{name})
                end
      
                def #{name}=(value)
                  __set_attribute(:#{name}, value)
                end
              CODE
            end
          end
        end
      end
    end
  end
end
