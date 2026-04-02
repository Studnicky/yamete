on run argv
    set volName to item 1 of argv
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {400, 100, 880, 380}
            set theViewOptions to the icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 100
            set background picture of theViewOptions to file ".background:dmg_background.png"
            set position of item (volName & ".app") of container window to {130, 170}
            set position of item "Applications" of container window to {350, 170}
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
