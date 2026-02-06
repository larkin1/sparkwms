### THIS IS ABANDONED AND UNFINISHED - I SWITCHED TO GO HALFWAY BECASUE RUST IS TOO HARD FOR A SMOOTHBRAIN LIKE MYSELF
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
 - [x] Interface with server
   - [x] Upload Commits
   - [x] Verify Connection
   - [x] Download Table
 - [x] Ensure Each Commit is sent once
 - [x] Wifi failsafe
#### Serverside
 - [x] Set up on supabase for now
 - [x] make tables and link em together
 - [x] move to self hosted/other alternatives to supabase (preferably cheaper than $25/month)
