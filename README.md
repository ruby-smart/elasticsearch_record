# ElasticsearchRecord

[![GitHub](https://img.shields.io/badge/github-ruby--smart/elasticsearch_record-blue.svg)](http://github.com/ruby-smart/elasticsearch_record)
[![Documentation](https://img.shields.io/badge/docs-rdoc.info-blue.svg)](http://rubydoc.info/gems/elasticsearch_record)

[![Gem Version](https://badge.fury.io/rb/elasticsearch_record.svg)](https://badge.fury.io/rb/elasticsearch_record)
[![License](https://img.shields.io/github/license/ruby-smart/elasticsearch_record)](docs/LICENSE)

[![Coverage Status](https://coveralls.io/repos/github/ruby-smart/elasticsearch_record/badge.svg?branch=main&kill_cache=1)](https://coveralls.io/github/ruby-smart/elasticsearch_record?branch=main)

ActiveRecord adapter for Elasticsearch

_ElasticsearchRecord is a ActiveRecord adapter and provides similar functionality for Elasticsearch._

-----

**PLEASE NOTE:**

- This is the `rails-7-1-stable`-branch, which only supports rails **7.1** _(see section 'Rails_Versions' for supported versions)_
- supports ActiveRecord ~> 7.1 + Elasticsearch >= 7.17
- added features up to Elasticsearch `8.17.1` _(tested against `8.19.14`)_
- _ES|QL_ queries _(`TYPE_ESQL` / the `esql.query` gate)_ require **Elasticsearch >= 8.11**, where the feature became
  generally available. All other features remain available from Elasticsearch `7.17`.

-----

## Rails versions

Supported rails versions:

### Rails 7.1:
_(since gem version 1.8)_

https://github.com/ruby-smart/elasticsearch_record/tree/rails-7-1-stable

[![rails-7-1-stable](https://img.shields.io/badge/rails-7.1.stable-orange.svg)](https://github.com/ruby-smart/elasticsearch_record/tree/rails-7-1-stable)

### Rails 7.0:
_(until gem version 1.7)_

https://github.com/ruby-smart/elasticsearch_record/tree/rails-7-0-stable

[![rails-7-0-stable](https://img.shields.io/badge/rails-7.0.stable-orange.svg)](https://github.com/ruby-smart/elasticsearch_record/tree/rails-7-0-stable)

-----

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'elasticsearch_record'

# alternative
gem 'elasticsearch_record', git: 'https://github.com/ruby-smart/elasticsearch_record', branch: 'rails-7-1-stable'
gem 'elasticsearch_record', git: 'https://github.com/ruby-smart/elasticsearch_record', branch: 'rails-7-0-stable'

```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install elasticsearch_record

-----

## Upgrading to 2.0

Version **2.0** contains breaking changes. Coming from **1.8.x**, check the following:

### 1. Table (index) names are resolved by default

Every table statement now resolves its name through `#_env_table_name`, so the
`table_name_prefix` / `table_name_suffix` no longer have to be applied by hand in migrations or database statements
_(which silently wrote into another environment's index)_.

```ruby
# 1.8.x - the prefix / suffix had to be applied manually
drop_table _env_table_name("settings")

# 2.0 - resolved on its own
drop_table "settings"
```

Existing migrations keep working - `_env_table_name` is idempotent and still public, so a
hand-resolved name resolves to the very same index. A new `decorate:`-argument opts out per
call, and `ElasticsearchRecord.decorate_table_names` acts as a global kill-switch.

_see @ [environment-related-table-name](#environment-related-table-name), [opting out with `decorate: false`](#opting-out-with-decorate-false) & [global kill-switch](#global-kill-switch)_

### 2. `select` raises on metadata fields

Metadata fields _(`_id`, `_score`, `_index`, ...)_ are not part of the `_source` node, so they
could never be resolved through the `_source`-filter this method builds - providing them
silently created a filter that never matched.

```ruby
Search.select(:_id)
# => ActiveRecord::UnknownAttributeReference
```

They are returned anyway and accessible on each record _(`Search.first._id`)_. To resolve the
metadata **without** transferring the `_source`, use the new `#meta_only!` method.

### 3. `restore_table` replaces its `open:`-argument with `unblock:`

A restore runs through a `clone`, so the restored table **inherits** the 'write'-block of its
source - the table was open, but read-only. `unblock:` _(default: `true`)_ releases it again.
`ModelApi#restore!` follows along.

```ruby
# 1.8.x
restore_table 'settings', from: 'settings-snapshot-2024', open: true

# 2.0
restore_table 'settings', from: 'settings-snapshot-2024', unblock: true
```

### 4. The plural table statements no longer skip AR-internal indices

`#open_tables`, `#close_tables`, `#refresh_tables` & `#truncate_tables` no longer subtract the
ActiveRecord-internal indices _(`schema_migrations` & `ar_internal_metadata`)_ - an explicitly
named index was silently dropped from the list. They now return an `Array` with an entry for
**every** provided name.

### 5. `truncate_table` raises for AR-internal indices

The statement runs a `drop` & `create` and would wipe the migration state.
`#drop_table` stays unguarded by design _(ActiveRecord resets both tables through it)_.

### 6. `esql` & `msearch` dropped their `async:`-argument

Both dispatch through the public `exec_query` now, since rails 7.1 made `internal_exec_query`
private - the `async:`-argument was dropped along with it.

-----

## Features
* ActiveRecord's `create, read, update & delete` behaviours
* Active Record Query Interface
  * query-chaining
  * scopes
  * additional relation methods to find records with `filter, must, must_not, should`
  * aggregated queries with Elasticsearch `aggregation` methods
  * resolve search response `hits`, `aggregations`, `buckets`, ... instead of ActiveRecord objects
  * `SQL` & `ES|QL` queries resolve their **tabular** response into records _(`find_by_sql` with a String query, `find_by_esql`)_
  * table (index) names are resolved within the current environment _(`table_name_prefix` / `table_name_suffix`)_
* Third-party gem support
  * access `elasticsearch-dsl` query builder through `model.search{ ... }`
* Schema
  * dump
  * create & update of tables _(indices)_ with mappings, settings & aliases
* Instrumentation for ElasticsearchRecord
  * logs Elasticsearch API-calls
  * shows Runtime in logs

## Notice
Since ActiveRecord does not have any configuration option to support transactions and 
Elasticsearch does **NOT** support transactions, it may be risky to ignore them.

As a default, transactions are 'silently swallowed' to not break any existing applications...

To raise an exception while using transactions on a ElasticsearchRecord model, the following flag can be enabled.
However enabling this flag will surely fail transactional tests _(prevent this with 'use_transactional_tests=false')_

```ruby
# config/initializers/elasticsearch_record.rb

# enable transactional exceptions
ElasticsearchRecord.error_on_transaction = true
```

## Setup

### a) Update your **database.yml** and add a elasticsearch connection:

```yml
 # config/database.yml
 
 development:
   primary:
     # <...>

   # elasticsearch
   elasticsearch:
     adapter: elasticsearch
     host: localhost:9200
     user: elastic
     password: '****'
     
     # enable ES verbose logging
     # log: true
     
     # add table (index) prefix & suffix to all 'tables'
     # table_name_prefix: 'app-'
     # table_name_suffix: '-development'
 
 production:
   # <...>

   # elasticsearch
   elasticsearch:
     # <...>
   
     # add table (index) prefix & suffix to all 'tables'
     # table_name_prefix: 'app-'
     # table_name_suffix: '-production'
 
 test:
   ...
 
 
```

### b) Require `elasticsearch_record/instrumentation` in your application.rb (if you want to...):

```ruby
# config/application.rb

require_relative "boot"

require "rails"
# Pick the frameworks you want:

# <...>

# add instrumentation
require 'elasticsearch_record/instrumentation'

module Application
   # ...
end
```

### c) Create a model that inherits from `ElasticsearchRecord::Base` model.

```ruby
# app/models/application_elasticsearch_record.rb

class ApplicationElasticsearchRecord < ElasticsearchRecord::Base
  # needs to be abstract
  self.abstract_class = true
end
```

Example class, that inherits from **ApplicationElasticsearchRecord**

```ruby
# app/models/search.rb
   
class Search < ApplicationElasticsearchRecord
  
end
```

### d) have FUN with your model:

```ruby
scope = Search
        .where(name: 'Custom Object Name')
        .where(token: nil)
        .filter(terms: {type: [:x, :y]})
        .limit(5)

# take the first object
obj = scope.take

# update the objects name
obj.update(name: "Not-So-Important")

# extend scope and update all docs
scope.where(kind: :undefined).offset(10).update_all(name: "New Name")

```

## Active Record Query Interface

### Refactored `where` method:
Different to the default where-method you can now use it in different ways.

Using it by default with a Hash, the method decides itself to either add a filter, or must_not clause.

_Hint: If not provided through `#kind`-method a default kind **:bool** will be used._

```ruby
# use it by default
Search.where(name: 'A nice object')
# > filter: {term: {name: 'A nice object'}}

# use it by default with an array
Search.where(name: ['A nice object','or other object'])
# > filter: {terms: {name: ['A nice object','or other object']}}

# use it by default with nil
Search.where(name: nil)
# > must_not: { exists: { field: 'name' } }

# -------------------------------------------------------------------

# use it with a prefix
Search.where(:should, term: {name: 'Mano'})
# > should: {term: {name: 'Mano'}}
```

### Result methods:
You can simply return RAW data without instantiating ActiveRecord objects:

```ruby

# returns the response RAW hits hash.
hits = Search.where(name: 'A nice object').hits
# > {"total"=>{"value"=>5, "relation"=>"eq"}, "max_score"=>1.0, "hits"=>[{ "_index": "search", "_type": "_doc", "_id": "abc123", "_score": 1.0, "_source": { "name": "A nice object", ...

# Returns the RAW +_source+ data from each hit - aka. +rows+.
results = Search.where(name: 'A nice object').results
# > [{ "name": "A nice object", ...

# returns the response RAW aggregations hash.
aggs = Search.where(name: 'A nice object').aggregate(:total, {sum: {field: :amount}}).aggregations
# > {"total"=>{"value"=>6722604.0}}

# returns the (nested) bucket values (and aggregated values) from the response aggregations.
buckets = Search.where(name: 'A nice object').aggregate(:total, {sum: {field: :amount}}).buckets
# > {"total"=>6722604.0}

# resolves RAW +_source+ data from each hit with a +point_in_time+ query (also includes _id)
# useful if you want more then 10000 results.
results = Search.where(name: 'A nice object').pit_results
# > [{ "_id": "abc123", "name": "A nice object", ...

# resolves ONLY the metadata nodes of each hit - the '_source' is not transferred at all.
# (this is the replacement for a - no longer supported - 'select(:_id)')
metas = Search.where(name: 'A nice object').meta_only!.results
# > [{ "_id": "abc123", "_index": "search", "_score": 1.0 }, ...

# returns the total value of the query without querying again (it uses the total value from the response)
scope = Search.where(name: 'A nice object').limit(5)
results_count = scope.count
# > 5
total = scope.total
# > 3335
```

### Available core query methods

- find_by_sql
- find_by_query
- find_by_esql
- esql
- msearch
- search

_see simple documentation about these methods @ {ElasticsearchRecord::Querying rubydoc}_

_(also see @ [github](https://github.com/ruby-smart/elasticsearch_record/blob/main/lib/elasticsearch_record/querying.rb) )_

### Available query/relation chain methods
- kind 
- configure
- aggregate
- refresh
- timeout
- query
- filter
- must_not
- must
- should
- aggregate
- select _(raises on metadata fields - see @ [Upgrading to 2.0](#2-select-raises-on-metadata-fields))_

_see simple documentation about these methods @ {ElasticsearchRecord::Relation::QueryMethods rubydoc}_

_(also see @ [github](https://github.com/ruby-smart/elasticsearch_record/blob/main/lib/elasticsearch_record/relation/query_methods.rb) )_

### Available calculation methods
- percentiles
- percentile_ranks
- cardinality
- average
- minimum
- maximum
- sum
- boxplot
- stats
- string_stats
- matrix_stats _(requires at least two columns)_
- median_absolute_deviation
- calculate

_see simple documentation about these methods @ {ElasticsearchRecord::Relation::CalculationMethods rubydoc}_

_(also see @ [github](https://github.com/ruby-smart/elasticsearch_record/blob/main/lib/elasticsearch_record/relation/calculation_methods.rb) )_

### Available query configuration methods

- hits_only! _(prevents to resolve aggs)_
- aggs_only! _(prevents to resolve hits / source data)_
- total_only! _(prevents to resolve aggs, hits / source data)_
- meta_only! _(resolves the metadata nodes (`_id`, `_score`, ...) of each hit without transferring the `_source`)_

### Available result methods
- aggregations
- buckets
- hits
- results
- total
- msearch
- agg_pluck
- composite
- point_in_time
- pit_results
- pit_delete

_see simple documentation about these methods @ {ElasticsearchRecord::Relation::ResultMethods rubydoc}_

_(also see @ [github](https://github.com/ruby-smart/elasticsearch_record/blob/main/lib/elasticsearch_record/relation/result_methods.rb) )_

### Additional methods 
- to_query

-----

## Useful model class attributes

### index_base_name
Rails resolves a pluralized underscore table_name from the class name by default - which will not work for some models.

To support a generic +table_name_prefix+ & +table_name_suffix+ from the _database.yml_, 
the 'index_base_name' provides a possibility to chain prefix, **base** and suffix.

```ruby
class UnusalStat < ApplicationElasticsearchRecord
  self.index_base_name = 'unusal-stats'
end

UnusalStat.where(year: 2023).to_query
# => {:index=>"app-unusal-stats-development", :body ...
```

### delegate_id_attribute
Rails resolves the primary_key's value by accessing the **#id** method.

Since Elasticsearch also supports an additional, independent **id** attribute,
it would only be able to access this through `_read_attribute(:id)`.

To also have the ability of accessing this attribute through the default, this flag can be enabled.

```ruby
class SearchUser < ApplicationElasticsearchRecord
  # attributes: id, name
end

# create new user within the index
user = SearchUser.create(id: 8, name: 'Parker')

# accessing the id, does NOT return the stored id by default - this will be delegated to the primary_key '_id'.
user.id
# => 'b2e34xa2'

# -- ENABLE delegation -------------------------------------------------------------------
SearchUser.delegate_id_attribute = true

# create new user within the index
user = SearchUser.create(id: 9, name: 'Pam')

# accessing the id accesses the stored attribute now
user.id
# => 9

# accessing the ES index id
user._id
# => 'xtf31bh8x'
```

## delegate_query_nil_limit
Elasticsearch's default value for queries without a **size** is forced to **10**.
To provide a similar behaviour as the (my)SQL interface,
this can be automatically set to the `max_result_window` value by calling `.limit(nil)` on the models' relation.

```ruby
SearchUser.where(name: 'Peter').limit(nil)
# returns a maximum of 10 items ...
# => [...]

# -- ENABLE delegation -------------------------------------------------------------------
SearchUser.delegate_query_nil_limit = true

SearchUser.where(name: 'Peter').limit(nil)
# returns up to 10_000 items ...
# => [...]

# hint: setting the 'max_result_window' can also be done by providing '__max__' wto the limit method: SearchUser.limit('__max__')

# hint: if you want more than 10_000 use the +#pit_results+ method!
```

## Useful model class methods
- auto_increment?
- max_result_window
- source_column_names
- searchable_column_names
- find_by_query
- msearch

## Useful model API methods
Quick access to model-related methods for easier access without creating a overcomplicated method call on the models connection...

Access these methods through the model class method `.api`.

```ruby
# returns mapping of model class
klass.api.mappings

# e.g. for ElasticUser model
SearchUser.api.mappings

# insert new raw data
SearchUser.api.insert([{name: 'Hans', age: 34}, {name: 'Peter', age: 22}])
```

### dangerous methods
* open!
* close!
* refresh!
* block!
* unblock!

### dangerous methods with args
* create!(...)
* clone!(...)
* rename!(...)
* backup!(...)
* restore!(...)
* reindex!(...)

### dangerous methods with confirm parameter
* drop!(confirm: true)
* truncate!(confirm: true)

### table methods
* mappings
* metas
* settings
* aliases
* state
* schema
* exists?

### plain methods
* alias_exists?(...)
* setting_exists?(...)
* mapping_exists?(...)
* meta_exists?(...)

### Fast insert, update, delete raw data
* index(...)
* insert(...)
* update(...)
* delete(...)
* bulk(...)

-----

## ActiveRecord ConnectionAdapters table-methods
Access these methods through the model class method `.connection`.

```ruby
# returns mapping of provided table (index)
klass.connection.table_mappings('table-name')
```

- table_mappings
- table_metas
- table_settings
- table_aliases
- table_state
- table_schema
- alias_exists?
- setting_exists?
- mapping_exists?
- meta_exists?
- max_result_window
- cluster_info
- cluster_settings
- cluster_health

## Active Record Schema migration methods
Access these methods through the model's connection or within any `Migration`.

### cluster actions:
- open_table
- open_tables
- close_table
- close_tables
- truncate_table
- truncate_tables
- refresh_table
- refresh_tables
- drop_table
- block_table
- unblock_table
- clone_table
- create_table
- change_table
- rename_table
- reindex_table
- backup_table
- restore_table

### table actions:
- change_meta
- remove_meta
- add_mapping
- change_mapping
- change_mapping_meta
- change_mapping_attributes
- remove_mapping
- add_setting
- change_setting
- remove_setting
- add_alias
- change_alias
- remove_alias


**Example migration:**

```ruby
class AddTests < ActiveRecord::Migration[7.1]
  def up
    create_table "assignments", if_not_exists: true do |t|
      t.string :key, primary_key: true
      t.text :value
      t.timestamps

      t.setting :number_of_shards, "1"
      t.setting :number_of_replicas, 0
    end

    # changes the auto-increment value
    change_meta "assignments", :auto_increment, 3625
    
    # removes the mapping 'updated_at' from the 'assignments' index.
    # the flag 'recreate' is required, since 'remove' is not supported for elasticsearch.
    # this will recreate the whole index (data will be LOST!!!)
    remove_mapping :assignments, :updated_at, recreate: true 
    
    create_table "settings", force: true do |t|
      t.mapping :created_at, :date
      t.mapping :key, :integer do |m|
        m.primary_key = true
        m.auto_increment = 10
      end
      t.mapping :status, :keyword
      t.mapping :updated_at, :date
      t.mapping :value, :text

      t.setting "index.number_of_replicas", "0"
      t.setting "index.number_of_shards", "1"
      t.setting "index.routing.allocation.include._tier_preference", "data_content"
    end

    add_mapping "settings", :active, :boolean do |m|
      m.comment = "Contains the active state"
    end

    change_table 'settings', force: true do |t|
      t.add_setting("index.search.idle.after", "20s")
      t.add_setting("index.shard.check_on_startup", true)
      t.add_alias('supersettings')
    end

    remove_alias('settings', :supersettings)
    remove_setting('settings', 'index.search.idle.after')

    change_table 'settings', force: true do |t|
      t.integer :amount_of_newbies
    end
    
    create_table "vintage", force: true do |t|
      t.primary_key :number
      t.string :name
      t.string :comments
      t.timestamps
    end

    change_table 'vintage', if_exists: true, recreate: true do |t|
      t.change_mapping :number, fields: {raw: {type: :keyword}}
      t.remove_mapping :number
    end
  end

  def down
    drop_table 'assignments'
    drop_table 'settings'
    drop_table 'vintage'
  end
end
```

## environment-related-table-name:
Table (index) names are resolved within the current environment, even if the environments share the
same cluster ...

This can be provided through the `database.yml` by using the `table_name_prefix/suffix` configuration keys.
**Every table statement applies them by default**, so a migration only ever names the table (index)
_base_ name.

**Example:**
Production uses a index suffix with '-pro', development uses '-dev' - they share the same cluster, but different indexes.

```yml
production:
  elasticsearch:
    # ...
    table_name_suffix: '-pro'

development:
  elasticsearch:
    # ...
    table_name_suffix: '-dev'
```

For the **settings** table / index this results in the following names:
* settings-pro
* settings-dev

A single migration can be created to be used within each environment:

```ruby
# Example migration
class AddSettings < ActiveRecord::Migration[7.1]
  def up
    # creates 'settings-pro' on production & 'settings-dev' on development
    create_table "settings", force: true do |t|
      t.mapping :created_at, :date
      t.mapping :key, :integer do |m|
        m.primary_key = true
        m.auto_increment = 10
      end
      t.mapping :status, :keyword
      t.mapping :updated_at, :date
      t.mapping :value, :text

      t.setting "index.number_of_replicas", "0"
      t.setting "index.number_of_shards", "1"
      t.setting "index.routing.allocation.include._tier_preference", "data_content"
    end
  end 
  
  def down
    drop_table "settings"
  end
end 
```

### opting out with `decorate: false`

Provide `decorate: false` to address an index by its **literal** name:

```ruby
# addresses 'settings-pro' - even from a '-dev' suffixed connection
drop_table "settings-pro", decorate: false
```

This is required in two cases:

* the name is **already resolved** _(e.g. `Model.table_name`, or a name read back from `#tables`)_
* the base name itself **starts with the prefix** or **ends with the suffix** - `_env_table_name`
  keeps itself idempotent through a `start_with?` / `end_with?` check and cannot tell such a name
  apart from an already resolved one

The flag only ever applies to table (index) names - `alias`, `mapping`, `setting` & `meta` names are
never touched. Statements taking **two** names _(`clone_table`, `rename_table`, `reindex_table`,
`restore_table`, `backup_table`, `create_table copy_from:`)_ resolve both.

The **schema statements** _(`table_exists?`, `table_schema`, `table_mappings`, `table_settings`,
`columns`, ...)_ are deliberately **not** decorated - ActiveRecord and the schema dumper call them
with an already resolved index name.

The `_env_table_name`-method itself is still public, so existing migrations keep working - it is now
redundant, since it resolves the very same name the statement would resolve on its own.

### global kill-switch

The default of a **not explicitly provided** `decorate:` argument is resolved from a global flag:

```ruby
# e.g. in an initializer
ElasticsearchRecord.decorate_table_names = false
```

Setting it to `false` restores the former, opt-in behaviour, where the decoration had to be applied
by hand through `_env_table_name`. A single statement can still opt in or out on its own, so
`decorate: true` keeps working while the flag is off:

```ruby
ElasticsearchRecord.decorate_table_names = false

drop_table "settings"                  # => drops 'settings'
drop_table "settings", decorate: true  # => drops 'settings-dev'
drop_table _env_table_name("settings") # => drops 'settings-dev' (the former syntax)
```

The schema dumper follows the flag: while the decoration is globally disabled it dumps the **full**
index name with an explicit `decorate: false`, so a dumped schema stays correct even if the flag is
flipped back on before it is loaded.

## Docs

[CHANGELOG](docs/CHANGELOG.md)

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/ruby-smart/elasticsearch_record).
This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](docs/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

A copy of the [LICENSE](docs/LICENSE) can be found @ the docs.

## Code of Conduct

Everyone interacting in the project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [CODE OF CONDUCT](docs/CODE_OF_CONDUCT.md).
