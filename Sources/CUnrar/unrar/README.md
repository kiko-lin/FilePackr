# unrar (vendorizado)

- Origen: https://www.rarlab.com/rar/unrarsrc-7.3.1.tar.gz
- SHA-256: `634900842a3737d9cc15bbcc71d4c74cc713437e0bca296a573424fe5f2660ab`
- Sin modificar. Solo se han quitado los ficheros de Visual Studio (`*.vcxproj`, `dll.rc`, `*.def`).
- Licencia: `license.txt` (freeware; permite usarlo para leer RAR, no para crear un compresor RAR).
- Qué se compila: `Package.swift` (target `CUnrar`, lista `unrarExcludedSources`).

Para actualizar: descargar la nueva versión, reemplazar este directorio (conservando este README),
actualizar versión/SHA-256 y comprobar que la lista de exclusión sigue cuadrando con `LIB_OBJ` +
`OBJECTS` del `makefile`.
