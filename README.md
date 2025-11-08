# SparkWMS
Mobile app to manage warehouse tracking written in flutter using rust behind the scenes.
This project is a WIP currently.
A python mockup can be found [here](https://github.com/larkin1/SparkWMS)
## Features
 - none yet
## TODO
#### GUI
 - [ ] Make Basic GUI
 - [ ] Integrate with rust core
 - [ ] flesh out GUI
 - [ ] Package and run proof of concept on android
 - [ ] flesh out and ship
#### Core
 - [ ] Interface with server
   - [ ] Upload Commits
   - [ ] Verify Connection
   - [ ] Download Table
 - [ ] Ensure Each Commit is sent once
 - [ ] Wifi failsafe
#### Serverside
 - [ ] Set up on supabase for now
 - [ ] make tables and link em together
 - [ ] move to self hosted/other alternatives to supabase (preferably cheaper than $25/month)