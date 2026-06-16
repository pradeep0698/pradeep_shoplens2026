import { ref, uploadBytesResumable, getDownloadURL } from 'firebase/storage';
import { storage } from './firebase';

export async function uploadVideo(
  file: File,
  onProgress?: (fraction: number) => void,
): Promise<{ fileName: string; downloadUrl: string }> {
  const fileName = file.name;
  const storageRef = ref(storage, `videos/${fileName}`);
  const task = uploadBytesResumable(storageRef, file);

  return new Promise((resolve, reject) => {
    task.on(
      'state_changed',
      (snapshot) => {
        onProgress?.(snapshot.bytesTransferred / snapshot.totalBytes);
      },
      reject,
      async () => {
        try {
          const downloadUrl = await getDownloadURL(task.snapshot.ref);
          resolve({ fileName, downloadUrl });
        } catch (err) {
          reject(err);
        }
      },
    );
  });
}
