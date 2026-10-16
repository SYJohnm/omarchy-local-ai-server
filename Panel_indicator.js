                Text {
                  visible: root.builtinOnPage("cacheType") && root.rowHasIgnoredFlag("cacheType")
                  text: "⚠ not in this build"
                  font.pixelSize: Style.font.small
                  font.italic: true
                  color: Style.warn
                }
