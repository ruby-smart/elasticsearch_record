# ElasticsearchRecord

ElasticsearchRecord provides ActiveRecord functionality for Elasticsearch indexed documents.

-----

**PLEASE NOTE:**
- This is still in development!
- Specs & documentation will follow. 
- You might experience BUGs and Exceptions...
- Currently supports only ActiveRecord 7.0 + Elasticsearch 8.4 (downgrade is planned)

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
* CRUD: Reading and Writing Data as you already use
* Query-chaining through the Active Record Query Interface
* Query interface with additional methods for ```filter, must, must_not, should```
* Aggregation queries
* Instrumentation for ElasticsearchRecord

## Contra - what it _(currently)_ can not
* Query-based associations like 'has_one' through a single _(or multiple)_ queries - aka. joins
* complex nested queries
* Create mappings / schema through migrations _(so no create_table, update_column, ...)_


## Setup

### a) Update your **database.yml** and add a elasticsearch connection:
```yml
 # config/database.yml
 
 development:
   ...
 
 production:
   ...
 
 test:
   ...
 
 # elasticsearch
 elasticsearch:
   adapter: elasticsearch
   host: localhost:9200
   user: elastic
   password: '****'
   log: true
```
_Alternatively you can change your 'development' connection with nested keys for your default database & elasticsearch..._

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
scope = Search.filter(term: {name: 'MyImportantObject'}).limit(5)
obj = scope.take

obj.update(name: "Not-So-Important")

scope.where(kind: :undefined).offset(10).update_all(name: "New Name")

```

## Active Record Query Interface

### Refactored ```where``` method:

Different to the default where-method you can now use it in different ways.

Using it by default with a Hash, the method decides itself to either add a filter, or must_not query.

_Hint: If not defined through ```#kind(...)``` it'll choose **:bool** as the default kind.
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

### Useful chain methods
- kind 
- configure
- aggregate
- query
- filter
- must_not
- must
- should
- aggregate

### Useful calculation methods
- percentiles
- cardinality
- average
- minimum
- maximum
- sum
- calculate

### Useful result methods
- aggregations
- hits
- results
- total
- msearch

### Additional methods 
- to_query

-----

### Useful model-class attributes
- index_base_name
- index_name_delimiter

### Useful model methods
- source_column_names
- searchable_column_names
- find_by_query
- msearch


## Docs

[CHANGELOG](./docs/CHANGELOG.md)

## Contributing

Bug reports and pull requests are welcome on GitHub at [elasticsearch_record](https://github.com/ruby-smart/elasticsearch_record).
This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](./docs/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

A copy of the [LICENSE](./docs/LICENSE.txt) can be found @ the docs.

## Code of Conduct

Everyone interacting in the project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [CODE OF CONDUCT](./docs/CODE_OF_CONDUCT.md).
