Add-Type -AssemblyName PresentationFramework
[System.Windows.MessageBox]::Show($env:runscript_error_message, 'Error', 'OK', 'Warning')