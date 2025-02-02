# frozen_string_literal: true

require_relative "lib/website/deployer/version"

Gem::Specification.new do |spec|
  spec.name = "website-deployer"
  spec.version = Website::Deployer::VERSION
  spec.authors = ["Carl Hörberg"]
  spec.email = ["carl@84codes.com"]

  spec.summary = "Website deployer"
  spec.description = "Renders websites and syncs to S3"
  spec.homepage = "https://github.com/84codes/website-deployer"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["allowed_push_host"] = ""

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "http://github.com/84codes/website-deployer.git"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "aws-sdk-cloudfront", "~> 1"
  spec.add_dependency "aws-sdk-s3", "~> 1"
  spec.add_dependency "mime-types", "~> 3"
end
