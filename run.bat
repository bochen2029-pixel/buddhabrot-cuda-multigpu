@echo off
rem Render the user's screenshot composition at 16K (16384 x 12288), 20B samples, 2000/200/20 iterations.
rem Override any flag on the command line, e.g. `run.bat --samples 5000000000 --output preview.png`.
pushd "%~dp0"
buddhabrot.exe ^
    --width 16384 ^
    --height 12288 ^
    --samples 20000000000 ^
    --iter-r 2000 ^
    --iter-g 200 ^
    --iter-b 20 ^
    --output buddhabrot_16k.png ^
    %*
popd
