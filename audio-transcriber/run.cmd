@echo off
setlocal
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" "%~dp0run.py" %*
  exit /b %errorlevel%
)
where py >nul 2>nul
if not errorlevel 1 (
  py -3 "%~dp0run.py" %*
  exit /b %errorlevel%
)
python "%~dp0run.py" %*
