# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module ColumnMethods
        extend ActiveSupport::Concern

        included do

          # toDo :define!
          # define_column_methods :blob, :tinyblob, :mediumblob, :longblob,
          #   :tinytext, :mediumtext, :longtext, :unsigned_integer, :unsigned_bigint,
          #   :unsigned_float, :unsigned_decimal
        end
      end
    end
  end
end
