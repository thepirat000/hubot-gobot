# Description:
#   A hubot build monitor for the go continuous integration server (http://www.thoughtworks.com/products/go-continuous-delivery).
#
# Dependencies:
#   "coffee-script": ">= 1.7",
#   "xml2js": ">=0.4.4",
#   "cron": ">= 1.0.1",
#   "underscore": ">=1.6.0"
#
# Configuration:
#   HUBOT_GOCI_EVENT_NOTIFIER_ROOM - The chatroom to write build events to
#   HUBOT_GOCI_SERVER - The server host name
#   HUBOT_GOCI_TLS_CA_FILE - The certificate authority file to use (default system)
#   HUBOT_GOCI_TLS_REJECT_UNAUTHORIZED - Reject unauthorized certificates (default true)
#   HUBOT_GOCD_PASSWORD - The BasicAuth password for GoCD
#   HUBOT_GOCD_PASSWORD - The BasicAuth password for GoCD
#   HUBOT_GOCI_TIMEZONE - The GoCD timezone to use (default none) i.e. +07:00
#   HUBOT_GOCI_PROJECTNAME_REGEXP - Regular expression to match project names (default none)
#
# Commands:
#   hubot build details [<query>] - Show current details for all the pipelines that matches the query
#   hubot build status - Shows a summary of broken pipelines
#
# Author:
#   Federico Colombo, based on fbernitt

fs = require('fs')
cron = require('cron')
_ = require('underscore')
xml2js = require 'xml2js'

parse_cctray = (xml, regExp) ->
  console.warn('Parsing XML ' + xml.length + ' bytes...')
  projects = []
  xmlParser = new xml2js.Parser()
  xmlParser.parseString xml, (err, result) ->
    if result.Projects.Project
      for project in result.Projects['Project']
        if not project.$.name.match(regExp)
          continue
        projects.push {"name": project.$.name, "lastBuildStatus": project.$.lastBuildStatus, "lastBuildLabel": project.$.lastBuildLabel, "lastBuildTime": project.$.lastBuildTime, "webUrl": project.$.webUrl, "activity": project.$.activity }
  projects

cctrayUrl = () ->
    "http://#{config.server}:8153/go/cctray.xml"

pipelineMapUrl = (pipeline, id) ->
    "http://#{config.server}:8153/go/pipelines/value_stream_map/#{pipeline}/#{id}"

config = 
    server: ""    
    room: ""
    filter: ""

loadConfig = (robot) ->
    config.room = process.env.HUBOT_GOCI_EVENT_NOTIFIER_ROOM
    config.server = process.env.HUBOT_GOCI_SERVER
    config.filter = process.env.HUBOT_GOCI_PROJECTNAME_REGEXP
    for k in Object.keys(config)
        if robot.brain.data.config.hasOwnProperty(k)
            config[k] = robot.brain.data.config[k]
    if not config.server?
        console.warn("hubot-gocd is not setup to fetch cctray.xml from a url (HUBOT_GOCI_SERVER is empty)!")
    if not config.room?
        console.warn("hubot-gocd is not setup announce build notifications into a chat room (HUBOT_GOCI_EVENT_NOTIFIER_ROOM is empty)!")

# MAIN
module.exports = (robot) ->
  robot.brain.data.gociProjects or= { }
  robot.brain.data.config or= { }
  
  startCronJob(robot)

  robot.respond /build status/i, (msg) ->
    buildStatus(robot, msg)

  robot.respond /build details\s*(.*)/i, (msg) ->
    buildDetails(robot, msg)

  robot.respond /config get\s*(.*)/i, (msg) ->
    configGet(robot, msg)

  robot.respond /config set\s(.*)\s(.*)/i, (msg) ->
    configSet(robot, msg)

  robot.respond /config reset/i, (msg) ->
    configReset(robot, msg)

  # exported functions for testing
  updateBrain: () ->
    updateBrain(robot)

  fetchAndCompare: (callback) ->
    fetchAndCompareData robot, callback

  buildStatus: (msg) ->
    buildStatus(robot, msg)

  startCronJob: () ->
    startCronJob(robot)

  cronTick: () ->
    crontTick(robot)

  robot.brain.on 'loaded', ->
    loadConfig(robot)
    updateBrain(robot)
    

# private functions
configGet = (robot, msg) ->
    if msg.match.length > 1 and config.hasOwnProperty(msg.match[1].trim())
        msg.send config[msg.match[1].trim()]

configSet = (robot, msg) ->
    configKey = msg.match[1].trim()
    configValue = msg.match[2]
    if msg.match.length > 2 and config.hasOwnProperty(configKey)
        config[configKey] = configValue
        robot.brain.data.config[configKey] = configValue
        msg.send configKey + ' set to ' + configValue
        robot.brain.save()
        resetBrain(robot)

configReset = (robot, msg) ->
    robot.brain.data.config = {}
    robot.brain.save()
    resetBrain(robot)
    loadConfig(robot)
    msg.send "Reset OK"

buildStatus = (robot, msg) ->
    someFailed = false
    fgi = _.groupBy robot.brain.data.gociProjects, (project) -> (project.name.split " :: ")[0]
    for pipeline in Object.keys(fgi)
        failed = false
        buildLabel = fgi[pipeline][0].lastBuildLabel
        pipelineId = buildLabel.replace(/\D/g,'')        
        message = { text: '*_' + pipeline + '_* (<' + pipelineMapUrl(pipeline, pipelineId) + '|' + buildLabel + '>)  is broken!', attachments: [] }
        for project in fgi[pipeline]
            if "Failure" == project.lastBuildStatus
                failed = true
                unixDt = Date.parse(project.lastBuildTime + process.env.HUBOT_GOCI_TIMEZONE).valueOf() / 1000
                name = project.name.split " :: "
                if (name.length is 3)
                    stage = name[1]
                    job = name[2]
                    attch = 
                        title: 'Stage <' + project.webUrl + '|' + stage + '> - Job <' + project.webUrl + '|' + job + '> FAILED'
                        footer: 'Last build: <!date^' + unixDt + '^{date_long_pretty} {time}^' + project.webUrl + '|stage>'
                        color: 'danger'
                    message.attachments.push attch
        if failed           
            someFailed = true 
            msg.send message
    if not someFailed
        msg.send "Good news, everyone! All green!"

buildDetails = (robot, msg) ->
    fgi = _.groupBy robot.brain.data.gociProjects, (project) -> (project.name.split " :: ")[0]
    cmdRegExp = new RegExp(msg.match[1].trim(), 'i') if msg.match.length > 1
    console.warn(cmdRegExp)
    noPipelines = true
    for pipeline in Object.keys(fgi)
        if cmdRegExp? and not pipeline.match(cmdRegExp)
            continue
        noPipelines = false
        buildLabel = fgi[pipeline][0].lastBuildLabel
        pipelineId = buildLabel.replace(/\D/g,'')        
        message = { text: '*_' + pipeline + '_* (<' + pipelineMapUrl(pipeline, pipelineId) + '|' + buildLabel + '>)', attachments: [] }
        for project in fgi[pipeline]
            name = project.name.split " :: "
            unixDt = Date.parse(project.lastBuildTime + process.env.HUBOT_GOCI_TIMEZONE).valueOf() / 1000
            if (name.length is 2) #it's a pipeline-stage project name
                attch = {
                    title: '<' + project.webUrl + '|' + name[1] + '>: ' + project.lastBuildStatus,
                    mrkdwn_in: ['title'],
                    color: if project.lastBuildStatus is "Failure" then "danger" else "good",
                    footer: 'Last build: <!date^' + unixDt + '^{date_long_pretty} {time}^' + project.webUrl + '|stage>'
                }
                message.attachments.push attch
        msg.send(message)
    if (noPipelines)
        msg.send("No pipelines matches the query #{cmdRegExp}")
                


parseData = (robot, callback) ->
  user = process.env.HUBOT_GOCD_USERNAME
  pass = process.env.HUBOT_GOCD_PASSWORD
  options =
	  ca: tlsCaFile(robot)
	  rejectUnauthorized: rejectUnauthorized()
  request = robot.http(cctrayUrl(), options)

  if (user && pass)
    auth = 'Basic ' + new Buffer(user + ':' + pass).toString('base64');
    request = request.headers(Authorization: auth, Accept: 'application/json')
  else
    request = request.headers(Accept: 'application/json')

  request.get() (err, res, body) ->
    if not err
      try
        regExp = new RegExp(config.filter ? '.*', 'i')
        projects = parse_cctray(body, regExp)
        callback? projects
      catch e
        if e instanceof TypeError
          console.warn("Invalid xml data fetched from #{cctrayUrl()}")
        else
          throw e
    else
      console.warn("Failed to fetch data from #{cctrayUrl()} with error : #{err}")

fetchAndCompareData = (robot, callback) ->
  parseData robot, (projects) ->
    changes = []
    for project in projects
      previous = robot.brain.data.gociProjects[project.name]
      if previous and previous.lastBuildStatus != project.lastBuildStatus
        changedStatus = if "Success" == project.lastBuildStatus then "Fixed" else "Failed"
        changes.push {"name": project.name, "type": changedStatus, "lastBuildLabel": project.lastBuildLabel}
    callback? changes

crontTick = (robot) ->
  fetchAndCompareData robot, (changes) ->
    if config.room?
      for change in changes
        if "Fixed" == change.type
          robot.messageRoom config.room, { text: "*@channel :+1: Good news*", attachments: [{ title: '*#{change.name} is green again in ##{change.lastBuildLabel}*', color: 'good' }] }
        else if "Failed" == change.type
          robot.messageRoom config.room, { text: "*@channel :-1: Bad news*", attachments: [{ title: '*#{change.name} FAILED in ##{change.lastBuildLabel}*', color: 'danger' }] }
  updateBrain(robot)

startCronJob = (robot) ->
  job = new cron.CronJob("0 */2 * * * *", ->
    crontTick(robot)
  )
  job.start()

updateBrain = (robot) ->
  parseData robot, (projects) ->
    robot.brain.data.gociProjects[project.name] = project for project in projects

resetBrain = (robot) ->
    robot.brain.data.gociProjects = {}
    updateBrain(robot)

tlsCaFile = (robot) ->
	if (typeof process.env.HUBOT_GOCI_TLS_CA_FILE isnt "undefined")
		return fs.readFileSync(process.env.HUBOT_GOCI_TLS_CA_FILE, "utf-8")
	else
		return undefined

rejectUnauthorized = () ->
	if (process.env.HUBOT_GOCI_TLS_REJECT_UNAUTHORIZED?)
		return JSON.parse(process.env.HUBOT_GOCI_TLS_REJECT_UNAUTHORIZED)
	else
		return true


