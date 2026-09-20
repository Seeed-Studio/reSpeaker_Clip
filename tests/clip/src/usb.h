/*
 * USB Mass Storage Class module
 * Exposes SD card as USB MSC device for file transfer
 */

#ifndef USB_H_
#define USB_H_

int usb_msc_init(void);
int usb_msc_disable(void); /* Disable the USB device (no SD remount); for SYSTEM OFF */

#endif /* USB_H_ */
