# frozen_string_literal: true

require_relative "lib/elasticsearch_record/version"

Gem::Specification.new do |spec|
  spec.name        = "elasticsearch_record"
  spec.version     = ElasticsearchRecord.version
  spec.authors     = ["Tobias Gonsior"]
  spec.email       = ["info@ruby-smart.org"]
  spec.summary     = "ActiveRecord adapter for Elasticsearch"
  spec.description = <<DESC
ElasticsearchRecord is a ActiveRecord adapter and provides similar functionality for Elasticsearch.
DESC

  spec.homepage              = "https://github.com/ruby-smart/elasticsearch_record"
  spec.license               = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = "https://github.com/ruby-smart/elasticsearch_record"
  spec.metadata['documentation_uri'] = 'https://rubydoc.info/gems/elasticsearch_record'
  spec.metadata["changelog_uri"]     = "#{spec.metadata["source_code_uri"]}/blob/main/docs/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end

  spec.require_paths = ["lib"]

  spec.add_dependency 'activerecord', '~> 7.0'
  spec.add_dependency 'elasticsearch', '>= 7.17'

  #spec.add_development_dependency 'coveralls_reborn', '~> 0.25'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rake', "~> 13.0"
  spec.add_development_dependency 'yard', '~> 0.9'
  spec.add_development_dependency 'yard-activesupport-concern', '~> 0.0.1'
  spec.add_development_dependency 'yard-relative_markdown_links', '>= 0.4'
end
