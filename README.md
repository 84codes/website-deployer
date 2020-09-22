# website-deployer

1. Receives commit POSTs from GitHub from [website repos]
1. Clones the repo in question
1. Starts the website ruby app
1. Generates a static site using wget against the website ruby app
1. Publishes the static website to S3/CF

Note: The Ruby version of this project and of website projects needs to match.

[website repos]: https://github.com/84codes?q=website&type=&language=
