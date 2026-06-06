"""
JSON schemas matching what the producer emits to each Event Hubs topic.

All fields are typed as StringType to avoid `from_json` silently nulling rows
when a CSV field is empty (Spark fails type coercion on "" -> int). Jobs cast
the numeric columns explicitly at usage.
"""
from pyspark.sql.types import StructType, StructField, StringType


def _string_schema(field_names):
    return StructType([StructField(n, StringType()) for n in field_names])


ACCIDENT_FIELDS = [
    "Accident_Index", "1st_Road_Class", "1st_Road_Number", "2nd_Road_Class",
    "2nd_Road_Number", "Accident_Severity", "Carriageway_Hazards", "Date",
    "Day_of_Week", "Did_Police_Officer_Attend_Scene_of_Accident",
    "Junction_Control", "Junction_Detail", "Latitude", "Light_Conditions",
    "Local_Authority_(District)", "Local_Authority_(Highway)",
    "Location_Easting_OSGR", "Location_Northing_OSGR", "Longitude",
    "LSOA_of_Accident_Location", "Number_of_Casualties", "Number_of_Vehicles",
    "Pedestrian_Crossing-Human_Control", "Pedestrian_Crossing-Physical_Facilities",
    "Police_Force", "Road_Surface_Conditions", "Road_Type",
    "Special_Conditions_at_Site", "Speed_limit", "Time", "Urban_or_Rural_Area",
    "Weather_Conditions", "Year", "InScotland",
]

VEHICLE_FIELDS = [
    "Accident_Index", "Age_Band_of_Driver", "Age_of_Vehicle",
    "Driver_Home_Area_Type", "Driver_IMD_Decile", "Engine_Capacity_.CC.",
    "Hit_Object_in_Carriageway", "Hit_Object_off_Carriageway",
    "Journey_Purpose_of_Driver", "Junction_Location", "make", "model",
    "Propulsion_Code", "Sex_of_Driver", "Skidding_and_Overturning",
    "Towing_and_Articulation", "Vehicle_Leaving_Carriageway",
    "Vehicle_Location.Restricted_Lane", "Vehicle_Manoeuvre", "Vehicle_Reference",
    "Vehicle_Type", "Was_Vehicle_Left_Hand_Drive", "X1st_Point_of_Impact", "Year",
]

ACCIDENT_SCHEMA = _string_schema(ACCIDENT_FIELDS)
VEHICLE_SCHEMA = _string_schema(VEHICLE_FIELDS)
