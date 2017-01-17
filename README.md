# hubot-gobot

GoCD integration bot

See [`src/gobot.coffee`](src/gobot.coffee) for full documentation.

## Description

This plugin is based on Folker Bernitt's [hubot-gocd](https://github.com/fbernitt/hubot-gocd) and enables hubot to react on GoCD build events as well as query the current build state of your projects.
It queries the cctray.xml status file every two minutes and if a build switched, e.g. from green to red, hubot announces it
to the defined chat channel.

## Installation

In hubot project repo, run:

`npm install hubot-gobot --save`

Then add **hubot-gobot** to your `external-scripts.json`:

```json
[
  "hubot-gobot"
]
```

You need to specify the following environment variables:

- HUBOT_GOCI_EVENT_NOTIFIER_ROOM: The room to send notifications to
- HUBOT_GOCI_SERVER: The GoCD server host name
- HUBOT_GOCI_TIMEZONE: (optional) The timezone on GoCD server, i.e. +07:00
- HUBOT_GOCI_PROJECTNAME_REGEXP: (optional) Regular expression to match the pipeline/stage/job names to consider

If your GoCD server requires authentication to access cctray.xml you can provide them by setting the environment variables:

- HUBOT_GOCD_USERNAME
- HUBOT_GOCD_PASSWORD

## Sample Interaction

```
user1>> hubot hello
hubot>> hello!
```

## NPM Module

https://www.npmjs.com/package/hubot-gobot
