# ElasticsearchRecord - CHANGELOG

## [1.0.1] - 2022-10-19
* [add] ```ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Nested``` class to cast nested values
* [add] **properties** to column definition (so they are also searchable by _Relation_ conditions)
* [add] exception for _Relation_ #pit_results if batch size is too large
* [add] a default _#find_by_id_-method to proved a 'fallback' functionality for the primary '_id' column
* [fix] nested properties are not cast for column-type "object"
* [fix] ```ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements``` fields and property detection
* [fix] ```ElasticsearchRecord::StatementCache::PartialQuery``` reference manipulation of cached hash _(missing .deep_dup )_
* [ref] ```ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object``` class to only cast object values
* [ref] ```Arel::Visitors::Elasticsearch#visit_Sort``` to detect a random sort with correct keyword: "**\_\_rand\_\_**"

## [1.0.0] - 2022-10-18
* [add] patch for ```ActiveRecord::Relation::Merger``` - to support AR-relations
* [add] ```ElasticsearchRecord::Relation#pit_results``` _offset_ & _yield_ support
* [add] individual instrumentation names for ```ElasticsearchRecord::Relation``` result methods (like: #aggregations)
* [rem] cleanup Debugging & logging
* [fix] quoting for any values
* [fix] calculation ```count``` method to support already known syntax (with column, distinct, limited, ...)
* [fix] ```Arel::Nodes``` to support additional args (query, kind, aggs, ...)
* [fix] _relation manager patch_ to not mash up different relations
* [fix] ```ElasticsearchRecord``` total calculation for failed queries
* [fix] ```ElasticsearchRecord::Relation#count``` to correctly _unscope_
* [fix] ```Arel::Visitors::Elasticsearch```
  * build query where-clauses without existing default query-"kind" 
  * directly fail if a grouping _(visit_Arel_Nodes_Grouping)_ was provided
  * forced _failed!_ state was not correctly claimed
  * buggy _assign_-method for nested arrays
* [fix] ```Arel::Collectors::ElasticsearchQuery```
  * claim for _argument_
  * delete key on _nil_ assign
* [ref] simplify ```Arel::Collectors::ElasticsearchQuery``` (remove stack & scoping)
* [ref] simplify ```Arel::Visitors::Elasticsearch``` to support binds (statement cache) and simple where predicates
* [ref] rename ```ElasticsearchRecord::Query#arguments``` -> _#query_arguments_

## [0.1.2] - 2022-09-23
* [fix] Records / Elasticsearch index with additional 'id' fields not recognizing
* [rem] unnecessary & overcomplicated .index_name_delimiter class attribute

## [0.1.1] - 2022-09-22
* [add] msearch for klass & relation
* [fix] Gemfile (remove duplicated requirements)
* [fix] gemspec (dependencies & descriptions)
* [fix] loading requirements, remove unused code
* [fix] quoting
* [fix] arel collector
* [fix] arel visitor sort & assignment
* [ref] results builder for multiple responses
* [ref] log_subscriber to hide index but show 'query time'
* [ref] model_schema attributes

## [0.1.0] - 2022-09-21
* Initial commit
* docs, version, structure
