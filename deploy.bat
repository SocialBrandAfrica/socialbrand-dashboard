@echo off
cd /d "C:\Users\User\Desktop\DIWAAIS\socialbrand-dashboard"
git add .
git commit -m "Dashboard update %date% %time%"
git push
echo.
echo Done! Changes will be live on dashboard.socialbrand.africa in about 60 seconds.
pause
