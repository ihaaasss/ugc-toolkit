# Downloads

Every file in this folder (except this README) automatically appears as a button
on the **Downloads** page of Ihsan Tech Fix.

- Button name = file name without extension (`-` and `_` become spaces): `Canon_Drivers.zip` → **Canon Drivers**
- One click downloads the file into the signed-in user's **Downloads** folder
- `.zip` files are also extracted into a folder of the same name, which then opens in Explorer
- GitHub rejects files over **100 MB**; keep large installers on the NAS instead

## Link buttons

`links.txt` in this folder turns each line into a button that opens a web page:

```
Name | https://url | optional description
```

Lines starting with `#` are ignored.
