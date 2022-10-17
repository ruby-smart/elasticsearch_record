# ElasticsearchRecord - CHANGELOG

## [1.0.0] - 2022-10-17
* [add] patch for ```ActiveRecord::Relation::Merger``` - to support AR-relations
* [rem] cleanup Debugging & logging
* [fix] quoting for any values
* [fix] calculation ```count``` method to support already known syntax (with column, distinct, limited, ...)
* [fix] ```Arel::Nodes``` to support additional args (query, kind, aggs, ...)
* [fix] _relation manager patch_ to not mash up different relations
* [fix] ```ElasticsearchRecord``` total calculation for failed queries
* [fix] ```Arel::Visitors::Elasticsearch```
  * build query where-clauses without existing default query-"kind" 
  * directly fail if a grouping _(visit_Arel_Nodes_Grouping)_ was provided
  * forced _failed!_ state was not correctly claimed
  * buggy _assign_-method for nested arrays
* [ref] simplify ```Arel::Collectors::ElasticsearchQuery``` (remove stack & scoping)
* [ref] simplify ```Arel::Visitors::Elasticsearch``` to support binds (statement cache) and simple where predicates

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
