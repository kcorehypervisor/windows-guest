@echo on
setlocal
rem WinPE helper. Called as: load-viostor.cmd E:
rem Copies viostor onto the WinPE ramdisk and loads it so setup can see the virtio disk.
set "SRC=%~1\viostor\${VIRTIO_OS}\amd64"
if not exist "%SRC%\viostor.inf" (
  echo viostor not found at %SRC%
  exit /b 1
)
mkdir X:\virtio-viostor
xcopy /E /I /Y "%SRC%\*" X:\virtio-viostor\
drvload X:\virtio-viostor\viostor.inf
exit /b %ERRORLEVEL%
