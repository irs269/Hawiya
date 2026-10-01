package km.hawiya.matcher;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Random;

/**
 * Empreintes SYNTHÉTIQUES pour les tests (aucune vraie empreinte dans le dépôt).
 *
 * Principe (simplifié de SFinGe) : un champ d'orientation de type « boucle »
 * (un noyau, un delta), puis un bruit aléatoire filtré plusieurs fois par un
 * filtre de Gabor orienté. Les crêtes apparaissent, avec des terminaisons et
 * des bifurcations (minuties) qui dépendent de la graine : deux graines
 * différentes donnent deux « doigts » différents.
 */
final class EmpreinteSynthetique {

    static final int TAILLE = 320;
    private static final double PERIODE = 9.0; // 0,45 mm à 500 dpi

    private EmpreinteSynthetique() {
    }

    /** Pixels 8 bits (crêtes sombres sur fond clair), TAILLE × TAILLE. */
    static byte[] generer(long graine) {
        var hasard = new Random(graine);
        int n = TAILLE;
        // Noyau et delta légèrement déplacés selon la graine.
        double cx = n * (0.45 + 0.1 * hasard.nextDouble());
        double cy = n * (0.35 + 0.1 * hasard.nextDouble());
        double dx = n * (0.35 + 0.3 * hasard.nextDouble());
        double dy = n * (0.80 + 0.05 * hasard.nextDouble());

        double[] orientation = new double[n * n];
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                orientation[y * n + x] = 0.5 * (Math.atan2(y - cy, x - cx) - Math.atan2(y - dy, x - dx));
            }
        }

        double[] image = new double[n * n];
        for (int i = 0; i < n * n; i++) {
            image[i] = hasard.nextDouble() < 0.02 ? (hasard.nextBoolean() ? 1 : -1) : 0;
        }
        for (int iteration = 0; iteration < 8; iteration++) {
            image = filtrer(image, orientation, n);
        }

        byte[] pixels = new byte[n * n];
        double rx = n * 0.42;
        double ry = n * 0.48;
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                double ex = (x - n / 2.0) / rx;
                double ey = (y - n / 2.0) / ry;
                boolean dansDoigt = ex * ex + ey * ey <= 1;
                int v = !dansDoigt ? 255 : image[y * n + x] > 0 ? 40 : 220;
                pixels[y * n + x] = (byte) v;
            }
        }
        return pixels;
    }

    /** Un passage de filtre de Gabor orienté selon le champ, puis saturation. */
    private static double[] filtrer(double[] src, double[] orientation, int n) {
        int r = 6;
        double sigma = 3.5;
        double[] sortie = new double[n * n];
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                double theta = orientation[y * n + x];
                double c = Math.cos(theta);
                double s = Math.sin(theta);
                double somme = 0;
                for (int j = -r; j <= r; j++) {
                    int yy = y + j;
                    if (yy < 0 || yy >= n) continue;
                    for (int i = -r; i <= r; i++) {
                        int xx = x + i;
                        if (xx < 0 || xx >= n) continue;
                        // Axe perpendiculaire aux crêtes : la sinusoïde varie le long de cet axe.
                        double perpendiculaire = i * c + j * s;
                        double poids = Math.exp(-(i * i + j * j) / (2 * sigma * sigma))
                                * Math.cos(2 * Math.PI * perpendiculaire / PERIODE);
                        somme += poids * src[yy * n + xx];
                    }
                }
                sortie[y * n + x] = Math.tanh(4 * somme);
            }
        }
        return sortie;
    }

    /** Rotation (degrés) + translation (pixels) + bruit : « nouvelle capture » du même doigt. */
    static byte[] transformer(byte[] src, double degres, int decalageX, int decalageY, long graineBruit) {
        int n = TAILLE;
        var hasard = new Random(graineBruit);
        double a = Math.toRadians(degres);
        double c = Math.cos(a);
        double s = Math.sin(a);
        byte[] sortie = new byte[n * n];
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                // Point source correspondant (rotation autour du centre, puis décalage).
                double u = x - n / 2.0 - decalageX;
                double v = y - n / 2.0 - decalageY;
                int sx = (int) Math.round(c * u + s * v + n / 2.0);
                int sy = (int) Math.round(-s * u + c * v + n / 2.0);
                int valeur = sx >= 0 && sy >= 0 && sx < n && sy < n ? src[sy * n + sx] & 0xFF : 255;
                valeur += (int) Math.round(hasard.nextGaussian() * 12);
                sortie[y * n + x] = (byte) Math.max(0, Math.min(255, valeur));
            }
        }
        return sortie;
    }

    /** Encodage PNG (pour tester l'API, qui reçoit des images encodées). */
    static byte[] png(byte[] pixels) throws IOException {
        var image = new BufferedImage(TAILLE, TAILLE, BufferedImage.TYPE_BYTE_GRAY);
        image.getRaster().setDataElements(0, 0, TAILLE, TAILLE, pixels);
        var sortie = new ByteArrayOutputStream();
        ImageIO.write(image, "png", sortie);
        return sortie.toByteArray();
    }

    static byte[] modele(byte[] pixels) {
        return Moteur.extraire(TAILLE, TAILLE, pixels, 500);
    }
}
