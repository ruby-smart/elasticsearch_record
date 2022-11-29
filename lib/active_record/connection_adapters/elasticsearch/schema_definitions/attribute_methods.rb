# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module AttributeMethods
        extend ActiveSupport::Concern

        included do
          attr_reader :state

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

          def __assign(attributes)
            attributes.each do |key, value|
              send("#{key}=", value)
            end
          end

          def invalid!(message, key=:base)
            errors.add(key, message)
            false
          end

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
        end

        class_methods do
          def build_attribute_methods!(*args)
            opts       = args.extract_options!
            opts[:key] ||= :attributes

            args.each do |name|
              class_eval <<-CODE, __FILE__, __LINE__ + 1
                def #{name}
                  @#{opts[:key]}[:#{name}]
                end
      
                def #{name}=(value)
                  @#{opts[:key]}[:#{name}] = value
                end
              CODE
            end

            # general reader methods to resolve keys & values
            class_eval <<-CODE, __FILE__, __LINE__ + 1
              def __#{opts[:key]}_keys
                @#{opts[:key]}.keys
              end

              def __#{opts[:key]}_values
                @#{opts[:key]}.values
              end
            CODE
          end
        end
      end
    end
  end
end
