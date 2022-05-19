# website-deployer

Gem that can render a static website and upload it to S3 and then invalidate CloudFront.

Used by our [website repos].

[website repos]: https://github.com/84codes?q=website&type=&language=

## Usage

Render locally:

    bundle exec render-website

Deploy locally:

    bundle exec deploy-website


# Github Action Workflow

Add it to the `Gemfile`:

```ruby
gem 'website-deployer', github: "84codes/website-deployer"
```

Set up secrets (see naming in YAML below) per website repository.
Add the following workflow to the website's actions:

```yaml
name: Website deployer

on:
  workflow_dispatch:
  push:
    branches:
      - master

jobs:
  website:
    uses: 84codes/website-deployer/.github/workflows/deploy.yml
    with:
      domain: www.cloudamqp.com
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

## Development

Build the gem

    gem build

Install the built gem

    gem install --local ./website-deployer-*

Try it in a website repo

    bundle update website-deployer

    bundle exec render-website
