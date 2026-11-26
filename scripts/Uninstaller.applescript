-- Uninstall EasyTeX
-- Removes EasyTeX and EasyTeX PLUS plus the files they create in your Library folder.
-- Everything is moved to the Trash (not deleted), so it can be put back until the Trash is emptied.
-- Your LaTeX projects are never touched.
--
-- Built into "Uninstall EasyTeX.app" by scripts/build-uninstaller.sh.
-- Developer test mode: set EASYTEX_UNINSTALL_ROOT to a folder that stands in for both the home folder
-- and the Applications folders; the uninstaller then runs without dialogs and returns a summary.

use AppleScript version "2.4"
use framework "Foundation"
use framework "AppKit"
use scripting additions

property appNames : {"EasyTeX", "EasyTeX PLUS"}
property bundleIDs : {"app.easytex.lite", "app.easytex.PLUS"}
property dialogTitle : "Uninstall EasyTeX"

on run
	set testRoot to system attribute "EASYTEX_UNINSTALL_ROOT"
	set testMode to (testRoot is not "")
	if testMode then
		set homeDir to testRoot & "/"
		set appDirs to {testRoot & "/Applications/"}
	else
		set homeDir to POSIX path of (path to home folder)
		set appDirs to {"/Applications/", homeDir & "Applications/"}
	end if
	set lib to homeDir & "Library/"

	-- Collect {label, path, preselected}
	set entries to {}
	repeat with n in appNames
		repeat with d in appDirs
			set p to (d as text) & (n as text) & ".app"
			if my pathExists(p) then set end of entries to {(n as text) & ".app  (" & my shortPath(p, homeDir) & ")", p, true}
		end repeat
	end repeat

	set supportItems to {}
	repeat with bid in bundleIDs
		set b to bid as text
		set end of supportItems to {"Preferences", lib & "Preferences/" & b & ".plist"}
		set end of supportItems to {"Caches", lib & "Caches/" & b}
		set end of supportItems to {"Web data", lib & "WebKit/" & b}
		set end of supportItems to {"Web data", lib & "HTTPStorages/" & b}
		set end of supportItems to {"Window state", lib & "Saved Application State/" & b & ".savedState"}
	end repeat
	repeat with s in supportItems
		set p to item 2 of s
		if my pathExists(p) then set end of entries to {(item 1 of s) & "  (" & my shortPath(p, homeDir) & ")", p, true}
	end repeat

	-- Optional: possibly shared with other TeX tools, so not selected by default.
	set p to lib & "TinyTeX"
	if my pathExists(p) then set end of entries to {"TinyTeX, installed by EasyTeX Lite; other apps may use it  (" & my shortPath(p, homeDir) & ")", p, false}
	set p to lib & "texlive"
	if my pathExists(p) then set end of entries to {"TeX cache, shared with other TeX installations  (" & my shortPath(p, homeDir) & ")", p, false}

	if (count of entries) is 0 then
		if testMode then return "NOTHING FOUND"
		display dialog "EasyTeX does not seem to be installed. Nothing to remove." buttons {"OK"} default button 1 with title dialogTitle with icon note
		return
	end if

	-- Let the user choose.
	set labels to {}
	set defaults to {}
	repeat with e in entries
		set end of labels to item 1 of e
		if item 3 of e then set end of defaults to item 1 of e
	end repeat
	if testMode then
		set chosen to defaults
	else
		set chosen to choose from list labels with title dialogTitle with prompt "These EasyTeX items will be moved to the Trash. Your LaTeX projects are not affected." & return & "Hold ⌘ to change the selection." default items defaults OK button name "Move to Trash" cancel button name "Cancel" with multiple selections allowed
		if chosen is false then return
		if (count of chosen) is 0 then return
	end if

	-- Quit running copies first.
	if not testMode then
		repeat with bid in bundleIDs
			if my isRunning(bid as text) then
				try
					with timeout of 5 seconds
						tell application id (bid as text) to quit
					end timeout
				end try
				repeat 40 times
					if not my isRunning(bid as text) then exit repeat
					delay 0.5
				end repeat
				if my isRunning(bid as text) then
					display dialog "EasyTeX is still running. Please quit it (save your work first), then open the uninstaller again." buttons {"OK"} default button 1 with title dialogTitle with icon caution
					return
				end if
			end if
		end repeat
	end if

	-- Move to Trash.
	set moved to {}
	set failed to {}
	repeat with e in entries
		if chosen contains (item 1 of e) then
			set p to item 2 of e
			if p ends with ".plist" and not testMode then
				-- Clear the preferences cache so the settings are really gone.
				repeat with bid in bundleIDs
					if p ends with ((bid as text) & ".plist") then
						try
							do shell script "defaults delete " & quoted form of (bid as text)
						end try
					end if
				end repeat
			end if
			set result_ to my trashItem(p)
			if result_ is false then
				set end of failed to my shortPath(p, homeDir)
			else
				set end of moved to result_
			end if
		end if
	end repeat

	if testMode then
		set AppleScript's text item delimiters to linefeed
		set summary to "MOVED " & (count of moved) & linefeed & (moved as text) & linefeed & "FAILED " & (count of failed) & linefeed & (failed as text)
		set AppleScript's text item delimiters to ""
		return summary
	end if

	if (count of failed) is 0 then
		display dialog "EasyTeX was removed. " & (count of moved) & " items were moved to the Trash." & return & return & "Empty the Trash to free the disk space." buttons {"Done"} default button 1 with title dialogTitle with icon note
	else
		set AppleScript's text item delimiters to return
		set failedText to failed as text
		set AppleScript's text item delimiters to ""
		display dialog (count of moved) & " items were moved to the Trash, but these could not be removed:" & return & return & failedText & return & return & "You can drag them to the Trash yourself." buttons {"OK"} default button 1 with title dialogTitle with icon caution
	end if
end run

on pathExists(p)
	return ((current application's NSFileManager's defaultManager()'s fileExistsAtPath:p) as boolean)
end pathExists

on isRunning(bid)
	set apps to current application's NSRunningApplication's runningApplicationsWithBundleIdentifier:bid
	return ((apps's |count|()) as integer) > 0
end isRunning

-- Returns the item's new path in the Trash, or false.
on trashItem(p)
	set fm to current application's NSFileManager's defaultManager()
	set u to current application's NSURL's fileURLWithPath:p
	set {ok, newURL, err} to fm's trashItemAtURL:u resultingItemURL:(reference) |error|:(reference)
	if ok as boolean then return (newURL's |path|()) as text
	-- Items owned by another user (e.g. an app installed by an admin): let Finder ask for a password.
	try
		tell application "Finder" to delete (POSIX file p as alias)
		return p & " (via Finder)"
	end try
	return false
end trashItem

on shortPath(p, homeDir)
	if p starts with homeDir then return "~/" & text ((length of homeDir) + 1) thru -1 of p
	return p
end shortPath
