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
#   HUBOT_GOCI_CONFIG_NAME - The default config name (will use the room name if not provided)
#   HUBOT_GOCI_EVENT_NOTIFIER_ROOM - The chatroom to write build events to
#   HUBOT_GOCI_SERVER - The server host name
#   HUBOT_GOCI_TLS_CA_FILE - The certificate authority file to use (default system)
#   HUBOT_GOCI_TLS_REJECT_UNAUTHORIZED - Reject unauthorized certificates (default true)
#   HUBOT_GOCD_USERNAME - The BasicAuth username for GoCD
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
#   21-03-2017 -- federicoc -- multi-config (server, channel) -- v0.0.8
#   30-06-2017 -- federicoc -- user/password fix, build details with no config id fix -- v0.0.9

fs = require("fs")
cron = require("cron")
_ = require("underscore")
xml2js = require "xml2js"

parse_cctray = (i, xml, regExp) ->
    console.warn("Parsing XML #{xml.length} bytes from #{config[i].server}...")
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
                    "url": pipelineMapUrl(i, names[0], pipelineId),
                    "id": pipelineId,
                    "subId": subId
                }
    projects

cctrayUrl = (i) ->
    "http://#{config[i].server}:8153/go/cctray.xml"

pipelineMapUrl = (i, pipeline, id) ->
    "http://#{config[i].server}:8153/go/pipelines/value_stream_map/#{pipeline}/#{id}"

pipelineInstanceUrl = (i, pipeline, id) ->
    "http://#{config[i].server}:8153/go/api/pipelines/#{pipeline}/instance/#{id}"

roomInfoUrl = (i, pipeline, id) ->
    "https://slack.com/api/channels.list?token=#{process.env.HUBOT_SLACK_TOKEN}"

config = [ {
    server: ""      #GoCD server hostname
    room: ""        #Room name to send the alerts
    filter: ""      #Regular expression to filter out the pipelines by name
    trigger: ""     #Trigger type, by status change or by date change ("status" or "date", default is "status")
    material: ""    #Indicate if the script should fetch material info ("on" or "off", default is "on")
    user: ""    
    passw: ""    
} ]

rooms = { }

loadConfig = (robot) ->
    config[0].room = process.env.HUBOT_GOCI_EVENT_NOTIFIER_ROOM
    config[0].server = process.env.HUBOT_GOCI_SERVER
    config[0].filter = process.env.HUBOT_GOCI_PROJECTNAME_REGEXP
    config[0].trigger = process.env.HUBOT_GOCI_TRIGGER ? "status"
    config[0].material = process.env.HUBOT_GOCI_FETCH_MATERIALS ? "on"
    config[0].user = process.env.HUBOT_GOCD_USERNAME
    config[0].passw = process.env.HUBOT_GOCD_PASSWORD
    i = 0
    for c in robot.brain.data.config
        while (config.length <= i)
            config.push({});
        for k in Object.keys(config[0])
            if c.hasOwnProperty(k)
                config[i][k] = c[k]
        if not config[i].server?
            console.warn("No server for config #{i}")
        if not config[i].room?
            console.warn("No room for config #{i}")
        i++

typeIsArray = Array.isArray || ( value ) -> return {}.toString.call( value ) is '[object Array]'

# MAIN
module.exports = (robot) ->
    robot.brain.data.gociProjects or= [ {} ]     #Array of dictionary of projects
    robot.brain.data.config or= [ ]           #Array of configs
  
    startCronJob(robot)

    robot.respond /build status\s+(\d+)/i, (msg) ->
        i = getConfigIndex msg.match[1]
        buildStatus(robot, msg, i)

    robot.respond /build status$/i, (msg) ->
        i = getLocalConfigIndex msg
        buildStatus(robot, msg, i)

    robot.respond /build details\s*$/i, (msg) ->
        i = getLocalConfigIndex msg
        buildDetails(robot, msg, i)

    robot.respond /build details\s+(\D.+)+/i, (msg) ->
        i = getLocalConfigIndex msg
        buildDetails(robot, msg, i, msg.match[1])

    robot.respond /build details\s+(\d+)\s*(.*)/i, (msg) ->
        i = getConfigIndex msg.match[1]
        buildDetails(robot, msg, i, msg.match[2])

    robot.respond /build instance\s+(\d+)\s+(.+)\s+(.+)/i, (msg) ->
        instanceInfo(robot, msg)

    robot.respond /config$/i, (msg) ->
        i = getLocalConfigIndex msg
        msg.send "Resolved config #{i}: #{JSON.stringify(config[i])}"

    robot.respond /config get\s+(\d+)\s+(.+)/i, (msg) ->
        configGet(robot, msg)

    robot.respond /config get \*/i, (msg) ->
        configGetAll(robot, msg)

    robot.respond /config set\s+(\d+)\s+(.+)\s+(.+)/i, (msg) ->
        configSet(robot, msg)

    robot.respond /config reset\s+(\d+)/i, (msg) ->
        configReset(robot, msg)

    # exported functions for testing
    updateBrain: () ->
        updateBrain(robot)

    fetchAndCompare: (i, callback) ->
        fetchAndCompareData i, robot, callback

    buildStatus: (msg) ->
        buildStatus(robot, msg, 0)

    startCronJob: () ->
        startCronJob(robot)

    cronTick: () ->
        crontTick(robot)

    robot.brain.on "loaded", ->
        if (!typeIsArray(robot.brain.data.gociProjects))
            resetBrain(robot, -1) 
        if (robot.brain.data.config && !typeIsArray(robot.brain.data.config))
            robot.brain.data.config = [ robot.brain.data.config ]
            robot.brain.save()
        loadConfig(robot)
        crontTick(robot)

# private functions
configGet = (robot, msg) ->
    if msg.match.length > 2
        i = getConfigIndex msg.match[1]
        qry = msg.match[2].trim()
        if (config[i].hasOwnProperty(qry) && qry != "passw")
            msg.send config[i][qry]
        else if qry is "brain"
            msg.send JSON.stringify robot.brain.data.gociProjects[i]
        else if qry is "*"
            sconfig = JSON.parse JSON.stringify config[i]
            sconfig.passw = "***"
            msg.send JSON.stringify sconfig

configGetAll = (robot, msg) ->
    message = ""
    for i in [0...config.length]
        sconfig = JSON.parse JSON.stringify config[i]
        sconfig.passw = "***"
        message += "#{i}: #{JSON.stringify(sconfig)}\n"
    msg.send message

configSet = (robot, msg) ->
    i = getConfigIndex msg.match[1], true
    configKey = msg.match[2].trim()
    configValue = msg.match[3]
    while (config.length <= i)
        config.push({});
    if msg.match.length > 2 and config[0].hasOwnProperty(configKey)
        config[i][configKey] = configValue
        robot.brain.data.config = config;
        robot.brain.save()
        resetBrain(robot, i)
        msg.send "#{configKey} set to #{configValue} for config #{i}: #{JSON.stringify robot.brain.data.config[i]}"

configReset = (robot, msg) ->
    i = getConfigIndex msg.match[1]
    config[i] = {}
    robot.brain.data.config = config
    robot.brain.save()
    resetBrain(robot, i)
    loadConfig(robot)
    msg.send "Reset OK for index #{i}"

#Command: build status N
buildStatus = (robot, msg, i) ->
    projects = _.filter robot.brain.data.gociProjects[i], (project) -> project.job and "Failure" == project.lastBuildStatus
    someIsGreen = _.some robot.brain.data.gociProjects[i], (project) -> project.job and "Success" == project.lastBuildStatus
    if projects.length is 0
        if someIsGreen
            msg.send "Good news, everyone! All green!"
        else
            msg.send("No pipelines on #{config[i].server}")
        return
    getMsgForPipelines i, robot, projects, (message) ->
        message.text = "Build status for server *#{config[i].server}*"
        msg.send(message)

#Command: build details N [regexp]
buildDetails = (robot, msg, i, regexp) ->
    projects = _.filter robot.brain.data.gociProjects[i], (project) -> project.job
    if regexp
        cmdRegExp = new RegExp(regexp, "i") 
        projects = _.filter projects, (project) -> project.pipeline.match(cmdRegExp)
    if projects.length is 0
        msg.send("No pipelines matches the given query on #{config[i].server}")
        return
    getMsgForPipelines i, robot, projects, (message) ->
        message.text = "Build details for server *#{config[i].server}*"
        msg.send(message)

fetchInstanceInfo = (i, robot, pipeline, id, callback) ->
    if config[i].material != "on"
        callback? pipeline, []
        return
    url = pipelineInstanceUrl(i, pipeline, id)
    request = getRequest(i, robot, url)
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

#Command: build instance N {pipeline} {id}
instanceInfo = (robot, msg) ->
    i = getConfigIndex msg.match[1]
    pipeline = msg.match[2]
    id = msg.match[3]
    fetchInstanceInfo i, robot, pipeline, id, (p, instance) ->
        if instance.name?
            url = pipelineMapUrl(i, pipeline, id)
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

getConfigIndex = (match, add) ->
    if (!match)
        throw new Error("Config index: no match given")
    i = parseInt match, 10
    if (add && i > config.length)
        throw new Error("Config index: incorrect index #{i}. Should be from 0 to #{config.length}.")
    else if (!add && i >= config.length)
        throw new Error("Config index: incorrect index #{i}. Should be from 0 to #{config.length-1}.")
    return i

getLocalConfigIndex = (msg) ->
    room_id = msg.message.room
    if (rooms.hasOwnProperty(room_id))
        #find room in config
        room = rooms[room_id]
        for i in [0...config.length]
                if (config[i].room == room)
                    msg.send "Querying server #{config[i].server}..."
                    return i
    return 0    

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

getMsgForPipelines = (i, robot, projects, callback) ->
    fgi = _.groupBy projects, (project) -> project.pipeline
    message = { text: "", attachments: [] }
    count = Object.keys(fgi).length
    materials = {}
    if config[i].material == "on" then console.info("Fetching material info for #{count} pipelines")
    for pipeline in Object.keys(fgi)
        fetchInstanceInfo i, robot, fgi[pipeline][0].pipeline, fgi[pipeline][0].id, (p, instance) ->
            materials[p] = getRevisions(instance)
            if --count == 0
                if config[i].material == "on" then console.info("Finished fetching material info")
                for pipeline in Object.keys(fgi)
                    material = if config[i].material == "on" then " Materials: #{materials[pipeline]}" else ""
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

getMsgForChange = (i, robot, change, callback) ->
    project = change.project
    newsType = if "Fixed" == change.type then "Good " else if "Failed" == change.type then "Bad " else ""
    color = if "Success" == project.lastBuildStatus then "good" else "danger"
    emo = if project.lastBuildStatus is "Failure" then ":no_entry:" else ":white_check_mark:"
    message = { 
        text: "<!channel> #{emo} #{newsType}news for pipeline *" + project.pipeline + "* (Label: <" + project.url + "|" + project.lastBuildLabel + "> on #{config[i].server})", 
        attachments: [{ 
            title: "<#{project.webUrl}|#{project.job}> on <#{project.webUrl}|#{project.stage}> has " + (if project.lastBuildStatus is "Failure" then "failed" else "succeeded"), 
            color: color
        }]
    }
    fetchInstanceInfo i, robot, project.pipeline, project.id, (p, instance) ->
        material = getRevisions(instance)
        if material.length > 0
            message.attachments[0].pretext = "Materials: #{material}"
        callback? message

getRequest = (i, robot, url) ->
    if (i > 0)
        user = config[i].user
        pass = config[i].passw
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

parseData = (i, robot, callback) ->
    request = getRequest(i, robot, cctrayUrl(i))
    request.get() (err, res, body) ->
        if not err
            regExp = new RegExp(config[i].filter ? ".*", "i")
            try
                projects = parse_cctray(i, body, regExp)
            catch e
                if e instanceof TypeError
                    console.warn("Invalid xml data fetched from #{cctrayUrl(i)} #{e}")
                    return
                else
                    throw e
            callback? i, projects
        else
            console.warn("Failed to fetch data from #{cctrayUrl(i)} with error : #{err}")

fetchAndCompareData = (i, robot, callback) ->
  parseData i, robot, (index, projects) ->
    changes = []
    for project in projects
      while (robot.brain.data.gociProjects.length <= index)
        robot.brain.data.gociProjects.push({});
      previous = robot.brain.data.gociProjects[index][project.name]
      if previous and previous.lastBuildTime != project.lastBuildTime
        changedStatus = if previous.lastBuildStatus == project.lastBuildStatus then "Changed" else if "Success" == project.lastBuildStatus then "Fixed" else "Failed"
        if (config[index].trigger == "status" and changedStatus != "Changed") or (config[index].trigger == "date")
          changes.push {"type": changedStatus, "project": project, "previousStatus": previous.lastBuildStatus, "currentStatus": project.lastBuildStatus, "previousBuildTime": previous.lastBuildTime, "currentBuildTime": project.lastBuildTime}
    callback? index, changes

crontTick = (robot) ->
    fetchRoomInfo(robot)
    for i in [0...config.length]
        if config[i].server?
            fetchAndCompareData i, robot, (index, changes) ->
                if config[index].room?
                    for change in changes
                        if change.project.job
                            getMsgForChange index, robot, change, (msg) ->
                                robot.messageRoom config[index].room, msg
    updateBrain(robot)

startCronJob = (robot) ->
  job = new cron.CronJob("0 */1 * * * *", ->
    crontTick(robot)
  )
  job.start()

getLastBuildDate = (project) ->
    Date.parse(project.lastBuildTime + process.env.HUBOT_GOCI_TIMEZONE).valueOf() / 1000

updateBrain = (robot) ->
    for i in [0...config.length]
        if config[i].server?
            parseData i, robot, (index, projects) ->
                for project in projects
                    while (robot.brain.data.gociProjects.length <= index)
                        robot.brain.data.gociProjects.push({});
                    robot.brain.data.gociProjects[index][project.name] = project

resetBrain = (robot, index) ->
    if (index == -1)
        robot.brain.data.gociProjects = []
    else
        robot.brain.data.gociProjects[index] = {}
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

#Fetch the room info to be able to map room_id->name
fetchRoomInfo = (robot) ->
    url = roomInfoUrl()
    request = getRequest(-1, robot, url)
    request.get() (err, res, body) ->
        if not err and res.statusCode == 200
            json = JSON.parse body
            for channel in json.channels
                rooms[channel.id] = '#' + channel.name
        else
            console.warn("Failed to fetch room info data with error : #{err}")