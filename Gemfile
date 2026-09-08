# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in elasticsearch_record.gemspec
gemspec

# Pin the Elasticsearch client to the 8.x line for local development & specs.
# The gemspec intentionally allows '>= 7.17', but the 9.x client sends an
# 'Accept: application/vnd.elasticsearch+json; compatible-with=9' header that
# 8.x servers reject with a media_type_header_exception (HTTP 400).
# Keep this in sync with the server you develop against.
gem 'elasticsearch', '~> 8.0'
