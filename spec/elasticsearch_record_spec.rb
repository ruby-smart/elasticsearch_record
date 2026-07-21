# frozen_string_literal: true

RSpec.describe ElasticsearchRecord do
  it "has a version number" do
    expect(ElasticsearchRecord::VERSION).not_to be nil
  end
end
