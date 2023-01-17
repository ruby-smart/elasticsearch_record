# ElasticsearchRecord

[![GitHub](https://img.shields.io/badge/github-ruby--smart/elasticsearch_record-blue.svg)](http://github.com/ruby-smart/elasticsearch_record)
[![Documentation](https://img.shields.io/badge/docs-rdoc.info-blue.svg)](http://rubydoc.info/gems/elasticsearch_record)

[![Gem Version](https://badge.fury.io/rb/elasticsearch_record.svg)](https://badge.fury.io/rb/elasticsearch_record)
[![License](https://img.shields.io/github/license/ruby-smart/elasticsearch_record)](docs/LICENSE.txt)

ActiveRecord adapter for Elasticsearch

_ElasticsearchRecord is a ActiveRecord adapter and provides similar functionality for Elasticsearch._

-----

**PLEASE NOTE:**

- This is still in **development**!
- Specs & documentation will follow. 
- You might experience BUGs and Exceptions...
- Currently supports only ActiveRecord 7.0 + Elasticsearch 8.4 _(downgrade for rails 6.x is planned in future versions)_

-----

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'elasticsearch_record'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install elasticsearch_record


## Features
* ActiveRecord's `create, read, update & delete` behaviours
* Active Record Query Interface
  * query-chaining
  * scopes
  * additional relation methods to find records with `filter, must, must_not, should`
  * aggregated queries with Elasticsearch `aggregation` methods
  * resolve search response `hits`, `aggregations`, `buckets`, ... instead of ActiveRecord objects
* Third-party gem support
  * access `elasticsearch-dsl` query builder through `model.search{ ... }`
* Schema
  * dump
  * create & update of tables _(indices)_ with mappings, settings & aliases
* Instrumentation for ElasticsearchRecord
  * logs Elasticsearch API-calls
  * shows Runtime in logs

## Contra - what it _(currently)_ can not
* Joins to other indexes or databases
* complex, combined or nested queries ```and, or, Model.arel ...```

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
     log: true
 
 production:
   ...
 
 test:
   ...
 
 
```

### b) Require ```elasticsearch_record/instrumentation``` in your application.rb (if you want to...):
```ruby
# config/application.rb
require_relative "boot"

require "rails"
# Pick the frameworks you want:

# ...
require 'elasticsearch_record/instrumentation'

module Application
   # ...
end
```

### c) Create a model that inherits from ```ElasticsearchRecord::Base``` model.
```ruby
# app/models/application_elasticsearch_record.rb
   
class Search < ElasticsearchRecord::Base
   
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

### Refactored ```where``` method:
Different to the default where-method you can now use it in different ways.

Using it by default with a Hash, the method decides itself to either add a filter, or must_not clause.

_Hint: If not provided through ```#kind```-method a default kind **:bool** will be used._
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

# returns the total value of the query without querying again (it uses the total value from the response)
scope = Search.where(name: 'A nice object').limit(5)
results_count = scope.count
# > 5
total = scope.total
# > 3335

```

### Available query/relation chain methods
- kind 
- configure
- aggregate
- refresh
- query
- filter
- must_not
- must
- should
- aggregate
- restrict 
- hits_only!
- aggs_only!
- total_only!

_see simple documentation about these methods @ [rubydoc](https://rubydoc.info/gems/elasticsearch_record/ElasticsearchRecord/Relation/QueryMethods)_

### Available calculation methods
- percentiles
- percentile_ranks
- cardinality
- average
- minimum
- maximum
- sum
- calculate

_see simple documentation about these methods @ [rubydoc](https://rubydoc.info/gems/elasticsearch_record/ElasticsearchRecord/Relation/CalculationMethods)_

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

_see simple documentation about these methods @ [rubydoc](https://rubydoc.info/gems/elasticsearch_record/ElasticsearchRecord/Relation/ResultMethods)_

### Additional methods 
- to_query

-----

### Useful model class attributes
- index_base_name
- relay_id_attribute

### Useful model class methods
- auto_increment?
- max_result_window
- source_column_names
- searchable_column_names
- find_by_query
- msearch

## ActiveRecord ConnectionAdapters table-methods
Access these methods through the model's connection.

```ruby
  # returns mapping of provided table (index)
  model.connection.table_mappings('table-name')
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

**cluster actions:**
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

**table actions:**
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

```ruby
# Example migration
class AddTests < ActiveRecord::Migration[7.0]
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

## Docs

[CHANGELOG](docs/CHANGELOG.md)

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/ruby-smart/elasticsearch_record).
This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](docs/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

A copy of the [LICENSE](docs/LICENSE.txt) can be found @ the docs.

## Code of Conduct

Everyone interacting in the project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [CODE OF CONDUCT](docs/CODE_OF_CONDUCT.md).
