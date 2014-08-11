dobambam2jira
=============

A command-line tool which downloads all your projects hosted on BamBam (dobambam.com) and dumps them in Jira-compatible JSON format.


Installation
------------

 * Download the git repo.
 * Install Ruby on your machine.
 * Run "gem install bundle" from the command line.
 * Run "bundle install" from the command line in the folder you downloaded.

Running dobambam2jira
---------------------

Run
```
bundle exec ruby dobambam2jira.rb -b https://<yourcompany>.dobambam.com -u <bambam_user_name> -p <bambam_password> > dump.json
```

Go into your Jira and import data from JSON-file.
