# frozen_string_literal: true

# Covers +ElasticsearchRecord::Tasks::ElasticsearchDatabaseTasks#check_current_protected_environment!+.
#
# Since rails 8.1 +ActiveRecord::Tasks::DatabaseTasks.check_protected_environments!+ - run by
# 'db:drop', 'db:purge', 'db:schema:load', 'db:test:prepare', ... - asks the TASKS CLASS of every
# database config, so a tasks class without the method aborts all of these tasks.
#
# see @ ActiveRecord::Tasks::AbstractTasks#check_current_protected_environment!
RSpec.describe ElasticsearchRecord::Tasks::ElasticsearchDatabaseTasks do
  subject(:tasks) { described_class.new(db_config) }

  let(:db_config) { ElasticsearchRecord::Base.connection_pool.db_config }

  describe '#check_current_protected_environment!' do
    it 'passes - the cluster stores no environment to protect' do
      expect { tasks.check_current_protected_environment!(db_config, ActiveRecord::Migration) }.not_to raise_error
    end

    it 'passes the check rails runs over the database configs' do
      allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:configs_for).and_return([db_config])

      expect { ActiveRecord::Tasks::DatabaseTasks.check_protected_environments!('test') }.not_to raise_error
    end
  end
end
