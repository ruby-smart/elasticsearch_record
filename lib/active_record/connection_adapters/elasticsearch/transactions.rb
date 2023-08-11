# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Transactions
        extend ActiveSupport::Concern

        def transaction(*)
          # since ActiveRecord does not have any configuration option to support transactions,
          # this will be always false
          # return super if supports_transactions?
          #
          # So, transactions are silently swallowed...
          yield
        end

        # Begins the transaction (and turns off auto-committing).
        def begin_db_transaction(*)
          _throw_transaction_exception!(:begin_db_transaction)
        end

        # Commits the transaction (and turns on auto-committing).
        def commit_db_transaction(*)
          _throw_transaction_exception!(:commit_db_transaction)
        end

        # rollback transaction
        def exec_rollback_db_transaction(*)
          _throw_transaction_exception!(:exec_rollback_db_transaction)
        end

        def create_savepoint(*)
          _throw_transaction_exception!(:create_savepoint)
        end

        def exec_rollback_to_savepoint(*)
          _throw_transaction_exception!(:exec_rollback_to_savepoint)
        end

        def release_savepoint(*)
          _throw_transaction_exception!(:release_savepoint)
        end

        private

        def _throw_transaction_exception!(method_name)
          return unless ElasticsearchRecord.error_on_transaction
          raise NotImplementedError, "'##{method_name}' is not supported by Elasticsearch.\nTry to prevent transactions or set the 'ElasticsearchRecord.error_on_transaction' to false!"
        end
      end
    end
  end
end