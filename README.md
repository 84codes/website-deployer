# website-deployer

Gem that can render a static website and upload it to S3 and then invalidate CloudFront.

Used by our [website repos].

[website repos]: https://github.com/84codes?q=website&type=&language=

## Development

Build the gem

    gem build

Install the built gem

    gem install --local ./website-deployer-*

Try it in a website repo

    bundle add website-deployer

    bundle exec render_website www.cloudamqp.com
