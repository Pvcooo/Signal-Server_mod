#!/bin/sh
#downloads SRTM3 height data and 
#converts it to sdf files for Signal-Server
#build srtm2sdf before using this script (./build srtm2sdf)

baseurl="https://web.archive.org/web/20191019205719/https://dds.cr.usgs.gov/srtm/version2_1/SRTM3/"
region="Eurasia/"
#region="Africa/"
#region="Islands/"
#region="North_America/"
#region="South_America/"

srtm3Dir="data/SRTM3/"
srtm2sdfDir="utils/sdf/"

#north bounds of height data to download
#for north in {44..55}
#do
	#east bounds of height data to download
#	for east in {010..019}
#	do
#	wget "${baseurl}${region}N${north}E${east}.hgt.zip" -P $srtm3Dir
#	done
#done

#get every listed .hgt.zip file in the server directory of the region
#wget $(lynx -dump -listonly "${baseurl}${region}" | grep http |
#	grep \.hgt.zip$ | awk '{print $2}') -P $srtm3Dir

unzip "${srtm3Dir}*.hgt.zip" -d $srtm3Dir

for file in "${srtm3Dir}"*.hgt
do
	./${srtm2sdfDir}srtm2sdf "$file" >> results.out
done

mv *.sdf $srtm3Dir
#rm "${srtm3Dir}"*.hgt "${srtm3Dir}"*.hgt.zip
