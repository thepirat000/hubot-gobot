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
#   HUBOT_GOCI_TRIGGER - Triggering mode "status" or "date". "status" (default): the alerts are triggered only when the status of a pipeline changes. "date": the alerts are triggered when build date changes regardless of the previous status.
#   HUBOT_GOCI_FETCH_MATERIALS - Indicate if the script should fetch material info ("on" or "off", default is "on")
#   
# Commands:
#   hubot build details [<regexp>] - Show current details for all the pipelines that matches the regular expression
#   hubot build status - Shows a summary of broken pipelines
#   hubot build instance <pipeline_name> <pipeline_id> - Shows information about an instance of a pipeline
#
# Author:
#   Federico Colombo, based on fbernitt
#
# Modifications:
#   21-01-2017 -- federicoc -- added material and instance info -- v0.0.5
#   27-01-2017 -- federicoc -- fixed bug on changes detection -- v0.0.7

fs = require("fs")
cron = require("cron")
_ = require("underscore")
xml2js = require "xml2js"

parse_cctray = (xml, regExp) ->
    console.warn("Parsing XML #{xml.length} bytes from #{config.server}...")
    projects = []
    xmlParser = new xml2js.Parser()
    xmlParser.parseString xml, (err, result) ->
        if result.Projects.Project
            for project in result.Projects["Project"]
                if not project.$.name.match(regExp)
                    continue
                names = project.$.name.split " :: "
                labels = project.$.lastBuildLabel.split " :: "
                pipelineId = labels[0].replace(/\D/g,"")  
                subId = if labels.length > 1 then labels[1] else ""
                projects.push {
                    "name": project.$.name, 
                    "lastBuildStatus": project.$.lastBuildStatus, 
                    "lastBuildLabel": project.$.lastBuildLabel, 
                    "lastBuildTime": project.$.lastBuildTime, 
                    "webUrl": project.$.webUrl, 
                    "activity": project.$.activity, 
                    "pipeline": names[0], 
                    "stage": if names.length > 1 then names[1] else "", 
                    "job": if names.length > 2 then names[2] else "",
                    "url": pipelineMapUrl(names[0], pipelineId),
                    "id": pipelineId,
                    "subId": subId
                }
    projects

cctrayUrl = () ->
    "http://#{config.server}:8153/go/cctray.xml"

pipelineMapUrl = (pipeline, id) ->
    "http://#{config.server}:8153/go/pipelines/value_stream_map/#{pipeline}/#{id}"

pipelineInstanceUrl = (pipeline, id) ->
    "http://#{config.server}:8153/go/api/pipelines/#{pipeline}/instance/#{id}"

config = 
    server: ""      #GoCD server hostname
    room: ""        #Room name to send the alerts
    filter: ""      #Regular expression to filter out the pipelines by name
    trigger: ""     #Trigger type, by status change or by date change ("status" or "date", default is "status")
    material: ""    #Indicate if the script should fetch material info ("on" or "off", default is "on")


loadConfig = (robot) ->
    config.room = process.env.HUBOT_GOCI_EVENT_NOTIFIER_ROOM
    config.server = process.env.HUBOT_GOCI_SERVER
    config.filter = process.env.HUBOT_GOCI_PROJECTNAME_REGEXP
    config.trigger = process.env.HUBOT_GOCI_TRIGGER ? "status"
    config.material = process.env.HUBOT_GOCI_FETCH_MATERIALS ? "on"
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

  robot.respond /build instance\s+(.+)\s+(.+)/i, (msg) ->
    instanceInfo(robot, msg)

  robot.respond /config get\s*(.*)/i, (msg) ->
    configGet(robot, msg)

  robot.respond /config set\s(.+)\s(.+)/i, (msg) ->
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

  robot.brain.on "loaded", ->
    loadConfig(robot)
    crontTick(robot)

# private functions
configGet = (robot, msg) ->
    if msg.match.length > 1
        qry = msg.match[1].trim()
        if config.hasOwnProperty(qry)
            msg.send config[qry]
        else if qry is "brain"
            msg.send JSON.stringify robot.brain.data.gociProjects
        else if qry is "*"
            msg.send JSON.stringify config

configSet = (robot, msg) ->
    configKey = msg.match[1].trim()
    configValue = msg.match[2]
    if msg.match.length > 2 and config.hasOwnProperty(configKey)
        config[configKey] = configValue
        robot.brain.data.config[configKey] = configValue
        msg.send "#{configKey} set to #{configValue}"
        robot.brain.save()
        resetBrain(robot)

configReset = (robot, msg) ->
    robot.brain.data.config = {}
    robot.brain.save()
    resetBrain(robot)
    loadConfig(robot)
    msg.send "Reset OK"

#Command: build status
buildStatus = (robot, msg) ->
    projects = _.filter robot.brain.data.gociProjects, (project) -> project.job and "Failure" == project.lastBuildStatus
    someIsGreen = _.some robot.brain.data.gociProjects, (project) -> project.job and "Success" == project.lastBuildStatus
    if projects.length is 0
        if someIsGreen
            msg.send "Good news, everyone! All green!"
        else
            msg.send("No pipelines on #{config.server}")
        return
    getMsgForPipelines robot, projects, (message) ->
        message.text = "Build status for server #{config.server}"
        msg.send(message)

#Command: build details [regexp]
buildDetails = (robot, msg) ->
    projects = _.filter robot.brain.data.gociProjects, (project) -> project.job
    if msg.match.length > 1    
        console.warn(cmdRegExp)
        cmdRegExp = new RegExp(msg.match[1].trim(), "i") 
        projects = _.filter projects, (project) -> project.pipeline.match(cmdRegExp)
    if projects.length is 0
        msg.send("No pipelines matches the given query on #{config.server}")
        return
    getMsgForPipelines robot, projects, (message) ->
        message.text = "Build details for server #{config.server}"
        msg.send(message)

fetchInstanceInfo = (robot, pipeline, id, callback) ->
    if config.material != "on"
        callback? pipeline, []
        return
    url = pipelineInstanceUrl(pipeline, id)
    request = getRequest(robot, url)
    request.get() (err, res, body) ->
        if not err
            try
                if not body.startsWith "{"
                    instance = { error: "Server response: #{body}" }
                else
                    instance = JSON.parse body
            catch e
                if e instanceof TypeError
                    console.warn("Invalid json data fetched from server")
                else
                    console.warn("Unknown error " + JSON.stringify(e))
                    throw e
        else
            console.warn("Failed to fetch data with error : #{err}")
        callback? pipeline, instance    

#Command: build instance {pipeline} {id}
instanceInfo = (robot, msg) ->
    pipeline = msg.match[1]
    id = msg.match[2]
    fetchInstanceInfo robot, pipeline, id, (p, instance) ->
        if instance.name?
            url = pipelineMapUrl(pipeline, id)
            materials = getRevisions(instance)
            message = { text: "Pipeline *#{p}* (id: <#{url}|#{id}>)\nMaterials: #{materials}\n", attachments: [] }
            stage_num = 1
            for stage in instance.stages
                job_num = 1
                stage_result = if stage.result is "Unknown" then "Active" else stage.result
                for job in stage.jobs
                    status = if job.state is "Completed" then job.result else job.state
                    color = if job.result is "Passed" then "good" else if job.result is "Failed" then "danger" else "warning"
                    emo = if stage.result is "Passed" then ":white_check_mark:" else if stage.result is "Failed" then ":no_entry:" else ":warning:"
                    attach = {
                        pretext: if job_num is 1 then "#{emo} Stage #{stage_num}: *#{stage.name}* overall result: *#{stage_result}*" else "",
                        title: "Job #{job.name} status is #{status}",
                        mrkdwn_in: ["title", "pretext"],
                        color: color
                    }
                    message.attachments.push attach
                    job_num++
                stage_num++
            msg.send(message)
        else if instance.error?
            msg.send(instance.error)

getRevisions = (instance) ->
    revisions = []
    if instance.build_cause?.material_revisions?
        for rev in instance.build_cause.material_revisions
            if rev.modifications?
                for mod in rev.modifications
                    type = rev.material.type
                    switch type
                        when "Tfs" 
                            txt = "[TFS] Changeset ##{mod.revision}"
                            if mod.comment? and mod.comment != "Unknown"
                                txt += ": " + mod.comment.replace(/\n/g," ")  
                        when "Pipeline"
                            revs = mod.revision.split "/"
                            txt = "[Pipeline] #{revs[0]} - #{revs[2]} (id: #{revs[1]})"
                        else
                            txt = "[#{type}] #{mod.revision}"
                            if mod.comment? and mod.comment != "Unknown"
                                txt += " (#{mod.comment})"
                    revisions.push txt
    revisions

getMsgForPipelines = (robot, projects, callback) ->
    fgi = _.groupBy projects, (project) -> project.pipeline
    message = { text: "", attachments: [] }
    count = Object.keys(fgi).length
    materials = {}
    if config.material == "on" then console.info("Fetching material info for #{count} pipelines")
    for pipeline in Object.keys(fgi)
        fetchInstanceInfo robot, fgi[pipeline][0].pipeline, fgi[pipeline][0].id, (p, instance) ->
            materials[p] = getRevisions(instance)
            if --count == 0
                if config.material == "on" then console.info("Finished fetching material info")
                for pipeline in Object.keys(fgi)
                    material = if config.material == "on" then " Materials: #{materials[pipeline]}" else ""
                    if _.some(fgi[pipeline], (p) -> p.lastBuildStatus is "Failure")
                        emo = ":no_entry:"
                    else if _.every(fgi[pipeline], (p) -> p.lastBuildStatus is "Success")
                        emo = ":white_check_mark:"
                    else
                        emo = ":warning:"
                    for project in fgi[pipeline]
                        unixDt = getLastBuildDate(project)
                        attch = {
                            pretext: if project is fgi[pipeline][0] then "#{emo} Pipeline: *#{pipeline}* (id: <#{project.url}|#{project.id}>)\n#{material}" else "",
                            title: "<#{project.webUrl}|#{project.job}> on <#{project.webUrl}|#{project.stage}> has " + if project.lastBuildStatus is "Failure" then "failed" else "succeeded",
                            mrkdwn_in: ["title", "pretext"],
                            color: if project.lastBuildStatus is "Failure" then "danger" else "good",
                            footer: "<!date^#{unixDt}^{date_short_pretty} {time}^#{project.webUrl}|stage> | #{project.lastBuildLabel} | #{project.activity}"
                        }
                        message.attachments.push attch
                callback? message

getMsgForChange = (robot, change, callback) ->
    project = change.project
    newsType = if "Fixed" == change.type then "Good " else if "Failed" == change.type then "Bad " else ""
    color = if "Success" == project.lastBuildStatus then "good" else "danger"
    emo = if project.lastBuildStatus is "Failure" then ":no_entry:" else ":white_check_mark:"
    message = { 
        text: "<!channel> #{emo} #{newsType}news for pipeline *" + project.pipeline + "* (Label: <" + project.url + "|" + project.lastBuildLabel + ">)", 
        attachments: [{ 
            title: "<#{project.webUrl}|#{project.job}> on <#{project.webUrl}|#{project.stage}> has " + (if project.lastBuildStatus is "Failure" then "failed" else "succeeded"), 
            color: color
        }]
    }
    fetchInstanceInfo robot, project.pipeline, project.id, (p, instance) ->
        material = getRevisions(instance)
        if material.length > 0
            message.attachments[0].pretext = "Materials: #{material}"
        callback? message

getRequest = (robot, url) ->
    user = process.env.HUBOT_GOCD_USERNAME
    pass = process.env.HUBOT_GOCD_PASSWORD
    options =
        ca: tlsCaFile(robot)
        rejectUnauthorized: rejectUnauthorized()
    request = robot.http(url, options)
    if (user && pass)
        auth = "Basic " + new Buffer(user + ":" + pass).toString("base64");
        request = request.headers(Authorization: auth, Accept: "application/json")
    else
        request = request.headers(Accept: "application/json")
    request

parseData = (robot, callback) ->
  request = getRequest(robot, cctrayUrl())
  request.get() (err, res, body) ->
    if not err
      try
        regExp = new RegExp(config.filter ? ".*", "i")
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
      if previous and previous.lastBuildTime != project.lastBuildTime
        changedStatus = if previous.lastBuildStatus == project.lastBuildStatus then "Changed" else if "Success" == project.lastBuildStatus then "Fixed" else "Failed"
        if (config.trigger == "status" and changedStatus != "Changed") or (config.trigger == "date")
          changes.push {"type": changedStatus, "project": project, "previousStatus": previous.lastBuildStatus, "currentStatus": project.lastBuildStatus, "previousBuildTime": previous.lastBuildTime, "currentBuildTime": project.lastBuildTime}
    callback? changes

crontTick = (robot) ->
  fetchAndCompareData robot, (changes) ->
    if config.room?
      for change in changes
        if change.project.job
          getMsgForChange robot, change, (msg) ->
            robot.messageRoom config.room, msg
  updateBrain(robot)

startCronJob = (robot) ->
  job = new cron.CronJob("0 */1 * * * *", ->
    crontTick(robot)
  )
  job.start()

getLastBuildDate = (project) ->
    Date.parse(project.lastBuildTime + process.env.HUBOT_GOCI_TIMEZONE).valueOf() / 1000

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


