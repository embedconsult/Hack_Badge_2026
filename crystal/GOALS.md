# Guarded goals

Set by the user. Read these before changing anything they cover. A change that breaks a guard must not become a default, however much it improves something else. If a guard can't be kept, stop and ask the user instead of trading it away.

## Sketch (Etch)

1. **No update over 250 ms.** This covers every pull the user can see while drawing, cleanup included. The badge logs each pull's ms; a pull over 250 ms fails the change.
2. **Quick render first.** Strokes appear right away with a row-window pull. Cleanup runs only when the knobs pause, in row bands of 250 ms or less, and knob motion always comes first.
3. **Light passes.** One pass gives light grey, and the user darkens a line by retracing it, about 5 passes to black. The pen point is the cursor: no crosshairs or tick marks on the canvas.
4. **No displaced ink.** No copies of strokes anywhere else on the panel, no seam lines at window edges, and every stroke must appear.
5. **Grey trails and pink ghosts are acceptable** in Sketch. Don't trade speed for them.

## How a change becomes the default

- **Camera proof:** a camera snap of long strokes, drawn the way a user draws (1, 3 and 5 passes, a pause, more strokes). Shell logs alone are not enough.
- **Timings:** the ms log for the same run, with no pull over 250 ms.
- **Report trade-offs to the user:** say in the report, not only in notes, what got worse and what got better.
- **Sign-off for Sketch:** no default flip for Sketch without the user's OK.
