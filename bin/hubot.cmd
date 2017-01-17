@echo off

call npm install
SETLOCAL
SET PATH=node_modules\.bin;node_modules\hubot\node_modules\.bin;%PATH%
SET HUBOT_SLACK_TOKEN=xoxb-127995828501-BGgKH4BzcEkDxP4q64YjhBmI

SET HUBOT_GOCI_EVENT_NOTIFIER_ROOM=#gocd
SET HUBOT_GOCI_SERVER=4usdlaws000110
  
SET HUBOT_GOCI_TIMEZONE=-08:00
SET HUBOT_GOCI_PROJECTNAME_REGEXP=BizworksReport

node_modules\.bin\hubot.cmd --name "gobot" %* 
