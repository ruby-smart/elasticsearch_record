# frozen_string_literal: true

RSpec.describe ElasticsearchRecord do
  it "has a version number" do
    expect(ElasticsearchRecord::VERSION).not_to be nil
  end

  it "exposes a gem_version" do
    expect(ElasticsearchRecord.gem_version).to be_a(Gem::Version)
  end
end
