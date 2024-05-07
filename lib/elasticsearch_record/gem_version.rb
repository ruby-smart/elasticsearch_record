# frozen_string_literal: true

module ElasticsearchRecord
  # Returns the version of the currently loaded module as a <tt>Gem::Version</tt>
  def self.gem_version
    Gem::Version.new VERSION::STRING
  end

  module VERSION
    MAJOR = 1
    MINOR = 7
    TINY  = 3
    PRE   = nil

    STRING = [MAJOR, MINOR, TINY, PRE].compact.join(".")

    def self.to_s
      STRING
    end
  end
end